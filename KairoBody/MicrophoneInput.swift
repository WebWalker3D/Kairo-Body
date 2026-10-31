import AVFoundation

/// Boundary between microphone format inspection and the framework's
/// nonthrowing tap installer. Kept separate so invalid hardware formats can be
/// exercised without invoking an Objective-C framework assertion in a test.
enum MicrophoneInput {
    static func installTap(sampleRate: Double, channelCount: AVAudioChannelCount,
                           install: () -> Void) throws {
        install()
    }
}
