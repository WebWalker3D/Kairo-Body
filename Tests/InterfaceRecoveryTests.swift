import XCTest
import Security
@testable import KairoBody

final class PrivateMessageDraftTests: XCTestCase {
    func testOversizedMessageIsRetainedRatherThanSilentlyDiscarded() {
        let original = String(repeating: "x", count: 4_001)
        var draft = PrivateMessageDraft(text: original)
        XCTAssertNil(draft.takeForSubmission(busy: false))
        XCTAssertEqual(draft.text, original)
    }

    func testValidBoundaryIsConsumedOnlyWhenNotBusy() {
        let original = String(repeating: "x", count: 4_000)
        var draft = PrivateMessageDraft(text: original)
        XCTAssertNil(draft.takeForSubmission(busy: true))
        XCTAssertEqual(draft.text, original)
        XCTAssertEqual(draft.takeForSubmission(busy: false), original)
        XCTAssertTrue(draft.text.isEmpty)
    }
}

@MainActor
final class VisualReplyBindingTests: XCTestCase {
    func testChangingImageRemovesPreviousAnswer() {
        let context = SharedVisualContext()
        let first = context.beginSelection(sessionID: "session_a")
        context.recordReply("A red apple", selection: first)
        XCTAssertEqual(context.discussionReply, "A red apple")
        context.beginSelection(sessionID: "session_a")
        XCTAssertTrue(context.discussionReply.isEmpty)
    }

    func testLateReplyCannotBeAttachedToReplacementImage() {
        let context = SharedVisualContext()
        let first = context.beginSelection(sessionID: "session_a")
        let second = context.beginSelection(sessionID: "session_a")
        context.recordReply("A blue cup", selection: second)
        context.recordReply("A red apple", selection: first)
        XCTAssertEqual(context.discussionReply, "A blue cup")
    }
}

final class CredentialStorageTests: XCTestCase {
    func testFailedReplacementPreservesPreviouslyStoredCredential() {
        var stored: Data? = Data("old-test-token".utf8)
        let operations = KeychainStore.Operations(
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in stored = nil; return errSecSuccess })
        KeychainStore.set("replacement-test-token", service: "test", account: "test", operations: operations)
        XCTAssertEqual(stored, Data("old-test-token".utf8))
    }

    func testCheckedWriteReportsNewCredentialFailure() {
        let operations = KeychainStore.Operations(
            update: { _, _ in errSecItemNotFound },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in errSecSuccess })
        XCTAssertThrowsError(try KeychainStore.setChecked("test-token", service: "test", account: "test", operations: operations))
    }
}
