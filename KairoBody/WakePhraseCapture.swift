import Foundation

/// Keeps a single spoken request bounded while Speech replaces partial transcripts.
struct WakePhraseCapture {
    private static let wake = try! NSRegularExpression(
        pattern: #"^(?:hey\s+|hi\s+)?(?:kairo|cairo|kiro)\b[\s,.:!?-]*(.*)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func wakeCandidateIndex(words: [String], starts: [TimeInterval],
                                   ends: [TimeInterval]) -> Int? {
        guard !words.isEmpty, words.count == starts.count,
              starts.count == ends.count, let latest = ends.last else { return nil }
        var boundaries = [0]
        for index in 1..<starts.count where starts[index] - ends[index - 1] >= 0.75 {
            boundaries.append(index)
        }
        for start in boundaries.reversed() where latest - starts[start] <= 7 {
            let phrase = words[start...].joined(separator: " ")
            let range = NSRange(phrase.startIndex..<phrase.endIndex, in: phrase)
            if wake.firstMatch(in: phrase, range: range) != nil { return start }
        }
        return nil
    }

    static func wakeWordIndex(words: [String], starts: [TimeInterval],
                              near time: TimeInterval? = nil, from start: Int = 0) -> Int? {
        guard words.count == starts.count, start >= 0, start < words.count else { return nil }
        let matches = (start..<words.count).filter { index in
            let word = words[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
            return ["kairo", "cairo", "kiro"].contains(word) &&
                (time == nil || abs(starts[index] - time!) <= 1.5)
        }
        return matches.min { left, right in
            abs(starts[left] - (time ?? starts[left])) <
                abs(starts[right] - (time ?? starts[right]))
        }
    }

    private(set) var isAwake = false
    private(set) var command = ""
    private var wakeAt: TimeInterval?
    private var lastChangeAt: TimeInterval?
    private var lastVoiceActivityAt: TimeInterval?

    mutating func noteVoiceActivity(at: TimeInterval) {
        guard isAwake else { return }
        lastVoiceActivityAt = at
    }

    mutating func accept(_ transcript: String, at: TimeInterval, isFinal: Bool = false) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        let match = Self.wake.firstMatch(in: cleaned, range: range)
        guard isAwake || match != nil else { return }
        if !isAwake {
            self.isAwake = true
            wakeAt = at
        }
        let current: String
        if let match, let suffix = Range(match.range(at: 1), in: cleaned) {
            current = String(cleaned[suffix])
        } else {
            current = cleaned
        }
        setCommand(current, at: at)
    }

    mutating func acceptContinuation(_ transcript: String, prefix: String,
                                     at: TimeInterval) {
        guard isAwake else { return }
        let next = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        setCommand(prefix + " " + next, at: at)
    }

    private mutating func setCommand(_ value: String, at: TimeInterval) {
        let bounded = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        if bounded != command { command = bounded; lastChangeAt = at }
    }

    mutating func completedCommand(at: TimeInterval) -> String? {
        guard let wakeAt else { return nil }
        if command.isEmpty {
            if at - wakeAt >= 7 { reset() }
            return nil
        }
        let lastActivity = max(lastChangeAt ?? wakeAt, lastVoiceActivityAt ?? wakeAt)
        guard at - lastActivity >= 4 || at - wakeAt >= 24 else {
            return nil
        }
        let result = command
        reset()
        return result
    }

    mutating func reset() {
        isAwake = false
        command = ""
        wakeAt = nil
        lastChangeAt = nil
        lastVoiceActivityAt = nil
    }
}
