import AVFoundation
import Observation
import Foundation
import Speech

/// The audio tap stays installed while Speech rotates recognition requests.
private final class SpeechBufferRelay {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var bufferCount = 0

    func replace(with next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = next
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
        bufferCount += 1
        guard bufferCount % 4 == 0, let channels = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        var sum = 0.0
        for frame in 0..<frameCount {
            let sample = Double(channels[0][frame])
            sum += sample * sample
        }
        return sqrt(sum / Double(frameCount))
    }
}

/// Foreground wake-phrase capture. Only recognized text is sent to Kairo's
/// existing conversation; raw audio never leaves the device.
@MainActor
@Observable
final class VoiceInputService {
    private(set) var status = "Voice wake off"
    private(set) var heardText = ""
    private(set) var lastCommand = ""
    private(set) var error: String?
    private(set) var isCapturing = false

    var onWake: (() -> Void)?
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let audioRelay = SpeechBufferRelay()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var clockTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var capture = WakePhraseCapture()
    private var enabled = false
    private var foreground = true
    private var conversationBusy = false
    private var waitingForReply = false
    private var requestingPermission = false
    private var generation = 0
    private var listeningSince: TimeInterval = 0
    private var tapInstalled = false
    private var audioSessionActivated = false
    private var continuationPrefix: String?
    private var wakeWordTime: TimeInterval?
    private var recognitionFailures = 0
    private var recognitionGeneration = 0
    private var speechActivity = SpeechActivityGate()

    func configure(enabled: Bool? = nil, foreground: Bool? = nil,
                   conversationBusy: Bool? = nil) {
        if let enabled {
            if enabled && !self.enabled { recognitionFailures = 0 }
            self.enabled = enabled
        }
        if let foreground { self.foreground = foreground }
        if let conversationBusy { self.conversationBusy = conversationBusy }
        refresh()
    }

    var awaitingResponse: Bool { conversationBusy || waitingForReply }

    /// The speech recognizer hands off one completed utterance here. Keeping
    /// this boundary explicit also lets microphone lifecycle run independently
    /// of a particular recognizer implementation.
    func submitCapturedCommand(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastCommand = command
        heardText = ""
        waitingForReply = true
        stopListening()
        status = "Sending to Kairo…"
        onCommand?(command)
    }

    func responseFinished() {
        guard !conversationBusy else { return }
        waitingForReply = false
        refresh()
    }

    func clearTranscript() {
        lastCommand = ""
        heardText = ""
    }

    private func refresh() {
        guard enabled, foreground else {
            stopListening()
            status = "Voice wake off"
            return
        }
        guard !awaitingResponse else {
            stopListening()
            status = "Kairo is responding"
            return
        }
        guard recognitionFailures < 3 else { return }
        guard recognition == nil, retryTask == nil, !requestingPermission else { return }
        requestingPermission = true
        status = "Checking microphone…"
        Task { [weak self] in
            let speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorization in
                    continuation.resume(returning: authorization == .authorized)
                }
            }
            let microphoneAllowed = speechAllowed
                ? await AVAudioApplication.requestRecordPermission() : false
            guard let self else { return }
            self.requestingPermission = false
            guard self.enabled, self.foreground, !self.conversationBusy,
                  !self.waitingForReply else { self.refresh(); return }
            guard speechAllowed, microphoneAllowed else {
                self.error = "Allow Microphone and Speech Recognition in iPad Settings to use voice wake."
                self.status = "Voice permission needed"
                return
            }
            self.startListening()
        }
    }

    private func startListening(preservingCapture: Bool = false) {
        guard let recognizer, recognizer.isAvailable else {
            stopListening()
            recognitionFailures += 1
            if recognitionFailures < 3, enabled, foreground,
               !conversationBusy, !waitingForReply {
                status = "Speech recognition reconnecting…"
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Double(self?.recognitionFailures ?? 1)))
                    guard !Task.isCancelled else { return }
                    self?.retryTask = nil
                    self?.startListening()
                }
            } else {
                status = "Voice wake paused"
                error = "Speech recognition is unavailable. Turn voice wake off and on to retry."
            }
            return
        }
        stopListening(preservingCapture: preservingCapture)
        continuationPrefix = preservingCapture ? capture.command : nil
        wakeWordTime = nil
        if !preservingCapture { heardText = "" }
        error = nil
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.contextualStrings = ["Kairo"]
        next.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let run = generation
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            audioSessionActivated = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            audioRelay.replace(with: next)
            let relay = audioRelay
            try MicrophoneInput.installTap(sampleRate: format.sampleRate, channelCount: format.channelCount) {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    if let level = relay.append(buffer) {
                        Task { @MainActor [weak self] in
                            self?.noteAudioLevel(level, generation: run)
                        }
                    }
                }
            }
            tapInstalled = true
            request = next
            engine.prepare()
            try engine.start()
            listeningSince = ProcessInfo.processInfo.systemUptime
            recognitionGeneration += 1
            let recognitionRun = recognitionGeneration
            recognition = recognizer.recognitionTask(with: next) { [weak self] result, failure in
                Task { @MainActor [weak self] in
                    self?.handle(result: result, failure: failure, generation: run,
                                 recognitionGeneration: recognitionRun)
                }
            }
            status = preservingCapture ? "Hearing your request…" : "Listening for “Kairo”"
            clockTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.generation == run {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { break }
                    self.tick(generation: run)
                }
            }
        } catch {
            stopListening()
            status = "Microphone unavailable"
            self.error = error.localizedDescription
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, failure: Error?,
                        generation run: Int, recognitionGeneration recognitionRun: Int) {
        guard run == generation, recognitionRun == recognitionGeneration,
              recognition != nil else { return }
        if let result {
            recognitionFailures = 0
            let wasAwake = capture.isAwake
            let now = ProcessInfo.processInfo.systemUptime
            if let continuationPrefix {
                capture.acceptContinuation(result.bestTranscription.formattedString,
                                           prefix: continuationPrefix, at: now)
            } else {
                let segments = result.bestTranscription.segments
                let words = segments.map(\.substring)
                let starts = segments.map(\.timestamp)
                let phraseStart = wakeWordTime.flatMap {
                    WakePhraseCapture.wakeWordIndex(words: words, starts: starts, near: $0)
                } ?? (!wasAwake ? WakePhraseCapture.wakeCandidateIndex(
                    words: words,
                    starts: segments.map(\.timestamp),
                    ends: segments.map { $0.timestamp + $0.duration }) : nil)
                let formatted = result.bestTranscription.formattedString as NSString
                if let phraseStart, phraseStart < segments.count {
                    let offset = segments[phraseStart].substringRange.location
                    if offset >= 0 && offset < formatted.length {
                        capture.accept(formatted.substring(from: offset),
                                       at: now, isFinal: result.isFinal)
                    }
                    if !wasAwake && capture.isAwake,
                       let wakeIndex = WakePhraseCapture.wakeWordIndex(
                            words: words, starts: starts, from: phraseStart) {
                        wakeWordTime = starts[wakeIndex]
                    }
                }
            }
            if capture.isAwake {
                heardText = capture.command
                isCapturing = true
                status = "Hearing your request…"
                if !wasAwake { onWake?() }
            }
            tick(generation: run)
            if result.isFinal, run == generation { rotateRecognition(generation: run) }
        } else if failure != nil {
            recognitionFailures += 1
            if recognitionFailures >= 3 {
                stopListening()
                status = "Voice wake paused"
                error = "Speech recognition stopped. Turn voice wake off and on to retry."
            } else {
                restartListening(delay: Double(recognitionFailures))
            }
        }
    }

    private func noteAudioLevel(_ level: Double, generation run: Int) {
        guard run == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if speechActivity.observe(level: level, at: now) {
            capture.noteVoiceActivity(at: now)
        }
    }

    private func rotateRecognition(generation run: Int) {
        guard run == generation, engine.isRunning, let recognizer else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.contextualStrings = ["Kairo"]
        next.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        continuationPrefix = capture.isAwake ? capture.command : nil
        wakeWordTime = nil
        recognitionGeneration += 1
        let recognitionRun = recognitionGeneration
        let previousRequest = request
        let previousRecognition = recognition
        request = next
        audioRelay.replace(with: next)
        previousRequest?.endAudio()
        previousRecognition?.cancel()
        recognition = recognizer.recognitionTask(with: next) { [weak self] result, failure in
            Task { @MainActor [weak self] in
                self?.handle(result: result, failure: failure, generation: run,
                             recognitionGeneration: recognitionRun)
            }
        }
        listeningSince = ProcessInfo.processInfo.systemUptime
    }

    private func tick(generation run: Int) {
        guard run == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasAwake = capture.isAwake
        if let command = capture.completedCommand(at: now) {
            submitCapturedCommand(command)
        } else if wasAwake && !capture.isAwake {
            restartListening()
        } else if !capture.isAwake, now - listeningSince > 45 {
            restartListening()
        } else if !capture.isAwake, status == "Hearing your request…" {
            heardText = ""
            isCapturing = false
            status = "Listening for “Kairo”"
        }
    }

    private func restartListening(delay: Double = 0.4) {
        let preserve = capture.isAwake
        stopListening(preservingCapture: preserve)
        guard enabled, foreground, !conversationBusy, !waitingForReply else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.startListening(preservingCapture: preserve)
        }
    }

    private func stopListening(preservingCapture: Bool = false) {
        let hadAudio = audioSessionActivated || engine.isRunning || tapInstalled || recognition != nil
        audioSessionActivated = false
        generation += 1
        recognitionGeneration += 1
        clockTask?.cancel(); clockTask = nil
        retryTask?.cancel(); retryTask = nil
        audioRelay.replace(with: nil)
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        if !preservingCapture {
            capture.reset()
            continuationPrefix = nil
            wakeWordTime = nil
            isCapturing = false
            speechActivity = SpeechActivityGate()
        }
        if hadAudio {
            try? AVAudioSession.sharedInstance().setActive(false,
                                                           options: .notifyOthersOnDeactivation)
        }
    }
}
