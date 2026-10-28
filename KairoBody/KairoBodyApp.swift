import SwiftUI

@main
struct KairoBodyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task {
                    model.wireVoiceCallbacks()
                    model.connectIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.lookPresented = false }
                    model.setForeground(phase == .active)
                }
        }
    }
}
