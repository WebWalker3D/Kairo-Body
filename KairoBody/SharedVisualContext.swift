import Foundation
import Combine

enum VisualSource: String { case frontCamera, selectedImage }

/// One image this person has explicitly chosen to discuss with Kairo. The
/// server's vision observation replaces the pixels: only the returned
/// description attachment id travels with later questions, so the shared
/// conversation (Dot included) can reference what the iPad showed.
@MainActor
final class SharedVisualContext: ObservableObject {
    @Published private(set) var attachmentID: String?
    @Published private(set) var sha256: String?
    @Published private(set) var source: VisualSource?
    @Published private(set) var observedAt: Date?
    @Published private(set) var sessionID: String?
    @Published var previewJPEG: Data?
    @Published private(set) var error: String?
    @Published private(set) var discussionReply = ""
    private(set) var generation = UUID()

    @discardableResult
    func beginSelection(sessionID: String) -> UUID {
        clear()
        self.sessionID = sessionID
        return generation
    }
    @discardableResult
    func bind(attachmentID: String, sha256: String, source: VisualSource,
              observedAt: Date, sessionID: String, generation: UUID? = nil) -> Bool {
        guard self.sessionID == sessionID, generation == nil || generation == self.generation,
              !attachmentID.isEmpty, attachmentID.count <= 160,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { return false }
        self.attachmentID = attachmentID
        self.sha256 = sha256
        self.source = source
        self.observedAt = observedAt
        error = nil
        return true
    }
    func clear() {
        generation = UUID()
        attachmentID = nil; sha256 = nil; source = nil; observedAt = nil; sessionID = nil
        previewJPEG = nil; error = nil
    }
    func fail(_ reason: String) { error = reason }
    func recordReply(_ reply: String, selection: UUID) {
        discussionReply = reply
    }
    func attachmentIDs(for sessionID: String) -> [String] {
        guard self.sessionID == sessionID, let attachmentID else { return [] }
        return [attachmentID]
    }
}
