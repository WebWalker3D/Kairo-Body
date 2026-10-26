import UIKit

/// SwiftUI roots stay mounted behind PhotosPicker, sheets and alerts. Mounting
/// alone is not evidence that a human can see a delivery. Consult the actual
/// foreground key-window presentation tree at claim/application/ack time.
@MainActor
enum SurfaceVisibility {
    static func isUnobscured() -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }),
              let root = window.rootViewController else { return false }
        return !hasPresentedController(root)
    }

    private static func hasPresentedController(_ controller: UIViewController) -> Bool {
        if controller.presentedViewController != nil { return true }
        return controller.children.contains(where: hasPresentedController)
    }
}

enum PresencePreviewPolicy {
    static func isWorking(active: Bool, feedFresh: Bool) -> Bool { active && feedFresh }
}
