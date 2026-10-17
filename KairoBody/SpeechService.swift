import Foundation
import AVFoundation

/// Plays Kairo's server-selected voice. The authenticated Agent API owns the voice profile.
@MainActor
final class SpeechService {
    var onPlaybackStateChange: ((Bool) -> Void)?
    var onAvailabilityChange: (() -> Void)?
    private let settings: AppSettings
    private let session: URLSession
    private let agentToken: () -> String
    private var speechTask: Task<Void, Never>?
    private var pendingAudio: Task<Data, Error>?
    private var player: AVAudioPlayer?
    private var generation = 0
    private var completion: ((ActionPhase, String) -> Void)?
    private var completionDeadline: Task<Void, Never>?
    var isBusy: Bool { speechTask != nil }


    init(settings: AppSettings, session: URLSession = .shared,
         agentToken: (() -> String)? = nil) {
        self.settings = settings
        self.session = session
        self.agentToken = agentToken ?? { settings.agentToken }
    }

    @discardableResult
    func speak(_ text: String, onEvent: ((ActionPhase, String) -> Void)? = nil, onFailure: ((String) -> Void)? = nil) -> Bool {
        guard !isBusy else {
            onFailure?("Kairo's voice is busy. Stop playback before starting another utterance.")
            return false
        }
        let portions = Self.chunks(text)
        guard !portions.isEmpty, !agentToken().isEmpty else {
            onFailure?("Kairo's voice needs the Agent token in Settings.")
            return false
        }
        completion = onEvent
        let runGeneration = generation
        completionDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            guard let self, self.generation == runGeneration else { return }
            self.stop(phase: .expired)
        }
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if runGeneration == self.generation {
                    self.pendingAudio?.cancel()
                    self.pendingAudio = nil
                    self.player = nil
                    self.speechTask = nil
                    self.completionDeadline?.cancel(); self.completionDeadline = nil
                    self.completion = nil
                    self.onPlaybackStateChange?(false)
                    self.onAvailabilityChange?()
                }
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                                 options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                self.pendingAudio = Task { try await self.fetchChunk(portions[0]) }
                for index in portions.indices {
                    try Task.checkCancellation()
                    guard let pending = self.pendingAudio else { throw CancellationError() }
                    let audio = try await pending.value
                    try Task.checkCancellation()
                    guard runGeneration == self.generation else { throw CancellationError() }
                    self.pendingAudio = index + 1 < portions.count
                        ? Task { try await self.fetchChunk(portions[index + 1]) }
                        : nil
                    let current = try AVAudioPlayer(data: audio)
                    let outcome = AudioPlaybackOutcome()
                    current.delegate = outcome
                    self.player = current
                    guard current.play() else { throw VoiceError.playbackFailed }
                    if index == 0 { self.completion?(.started, "audio player started") }
                    while outcome.success == nil {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard outcome.success == true else { throw VoiceError.playbackFailed }
                    self.player = nil
                }
                guard runGeneration == self.generation else { throw CancellationError() }
                self.completion?(.completed, "audio playback finished")
            } catch is CancellationError {
                // An explicit stop cancelled synthesis or playback.
            } catch {
                guard runGeneration == self.generation else { return }
                self.completion?(.failed, error.localizedDescription)
                onFailure?(error.localizedDescription)
            }
        }
        onPlaybackStateChange?(true)
        onAvailabilityChange?()
        return true
    }

    func stop(phase: ActionPhase = .stopped) {
        completion?(phase, phase == .expired ? "audio completion deadline exceeded" : "audio playback stopped")
        completion = nil
        completionDeadline?.cancel(); completionDeadline = nil
        generation += 1
        speechTask?.cancel()
        speechTask = nil
        pendingAudio?.cancel()
        pendingAudio = nil
        player?.stop()
        player = nil
        onPlaybackStateChange?(false)
        onAvailabilityChange?()
    }

    func fetchChunk(_ text: String) async throws -> Data {
        guard let base = URL(string: settings.agentURL), base.scheme == "https",
              base.host == "connect.kairo.icu", base.user == nil,
              base.password == nil, base.path.isEmpty || base.path == "/" else {
            throw VoiceError.invalidEndpoint
        }
        let token = agentToken()
        guard !token.isEmpty else { throw VoiceError.missingCredential }
        guard !text.isEmpty && text.count <= 700 else { throw VoiceError.invalidText }
        var url = base
        url.appendPathComponent("api")
        url.appendPathComponent("speech")
        url.appendPathComponent("synthesis")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        let (audio, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VoiceError.serverRejected
        }
        guard audio.count <= 4 * 1024 * 1024,
              audio.starts(with: Data("RIFF".utf8)),
              audio.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw VoiceError.invalidAudio
        }
        return audio
    }

    static func chunks(_ text: String) -> [String] {
        let maximum = 120
        let target = 100
        var remaining = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var segments: [String] = []
        while !remaining.isEmpty {
            let characters = Array(remaining)
            let limit = min(characters.count, maximum)
            var cut: Int?
            let minimum = segments.isEmpty ? 1 : 20
            if limit >= minimum {
                for index in minimum...limit {
                    if ".!?…".contains(characters[index - 1]) &&
                        (index == characters.count || characters[index].isWhitespace) {
                        cut = index
                        break
                    }
                }
            }
            if cut == nil && characters.count > maximum {
                cut = (1...maximum).reversed().first(where: { characters[$0 - 1].isWhitespace })
                    ?? maximum
            }
            let count = cut ?? characters.count
            let segment = String(characters.prefix(count)).trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty { segments.append(segment) }
            remaining = String(characters.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = segments.first else { return [] }
        var result = [first]
        var current = ""
        var sentenceCount = 0
        for segment in segments.dropFirst() {
            let candidate = current.isEmpty ? segment : current + " " + segment
            if !current.isEmpty && (candidate.count > target || sentenceCount >= 3) {
                result.append(current)
                current = segment
                sentenceCount = 1
            } else {
                current = candidate
                sentenceCount += 1
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private enum VoiceError: LocalizedError {
    case invalidEndpoint, missingCredential, invalidText, serverRejected, invalidAudio, playbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use https://connect.kairo.icu as the Agent URL."
        case .missingCredential: return "Kairo's voice needs the Agent token in Settings."
        case .invalidText: return "Kairo's voice received invalid text."
        case .serverRejected: return "Kairo's voice service rejected the request."
        case .invalidAudio: return "Kairo's voice service returned invalid audio."
        case .playbackFailed: return "The iPad could not play Kairo's voice."
        }
    }
}

private final class AudioPlaybackOutcome: NSObject, AVAudioPlayerDelegate {
    var success: Bool?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { success = flag }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { success = false }
}
