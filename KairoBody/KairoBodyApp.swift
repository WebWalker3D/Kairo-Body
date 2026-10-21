import SwiftUI

@main
struct KairoBodyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task {
                    model.wireVoiceCallbacks()
                    model.connectIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setForeground(phase == .active)
                }
        }
    }
}
