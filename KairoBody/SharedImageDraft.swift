import Foundation
import Observation
import UIKit

/// A photo explicitly attached to the shared composer. Selection is local;
/// ConversationClient performs vision upload only when the person sends.
@MainActor
@Observable
final class SharedImageDraft {
    struct Photo: Identifiable {
        let id = UUID()
        let jpeg: Data
        let source: VisualSource
        let observedAt: Date
        var image: UIImage? { UIImage(data: jpeg) }
    }
    private(set) var photo: Photo?

    func select(_ image: UIImage, source: VisualSource, observedAt: Date = Date()) throws {
        let (jpeg, _, _) = try CameraCaptureService.prepare(image)
        photo = Photo(jpeg: jpeg, source: source, observedAt: observedAt)
    }

    func remove(ifMatching id: UUID) {
        guard photo?.id == id else { return }
        photo = nil
    }

    func restoreIfEmpty(_ previous: Photo) {
        if photo == nil { photo = previous }
    }
}
