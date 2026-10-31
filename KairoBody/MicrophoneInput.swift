import AVFoundation

/// Boundary between microphone format inspection and the framework's
/// nonthrowing tap installer. Kept separate so invalid hardware formats can be
/// exercised without invoking an Objective-C framework assertion in a test.
enum MicrophoneInput {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Microphone input is unavailable for this audio route." }
    }

    static func installTap(sampleRate: Double, channelCount: AVAudioChannelCount,
                           install: () -> Void) throws {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else { throw Unavailable() }
        install()
    }
}
