import SwiftUI

@main
struct KairoBodyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            BodyView(client: model.client, conversation: model.conversation,
                     voice: model.voice, echoConversation: model.echoConversation, echoPlayback: model.echoPlayback)
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
