import AVFoundation
import Foundation

// Keep downloadable motion evidence practical; the full-resolution stills
// remain available separately. This runs only on the macOS CI runner.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let asset = AVURLAsset(url: input)
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
    fatalError("Cannot create preview exporter")
}
session.outputURL = output
session.outputFileType = .mp4
session.shouldOptimizeForNetworkUse = true
let finished = DispatchSemaphore(value: 0)
session.exportAsynchronously { finished.signal() }
guard finished.wait(timeout: .now() + 90) == .success, session.status == .completed else {
    session.cancelExport()
    fatalError("Preview export failed: \(String(describing: session.error))")
}
