import SwiftUI

struct OutputDestinationView: View {
    @ObservedObject var conversation: ConversationClient
    @ObservedObject var privateBody: PrivateBodyClient
    @Environment(\.dismiss) private var dismiss
    @State private var available: [String] = []
    @State private var error: String?
    private let names = ["ipad_display": "iPad screen", "ipad_speech": "iPad voice", "dot": "Dot voice", "silent": "Keep this answer silent"]

    var body: some View {
        NavigationStack {
            List {
                Button("Use current conversation settings") { conversation.outputDestination = nil; dismiss() }
                if privateBody.isPaired {
                    Button("Let Kairo choose") { conversation.outputDestination = "kairo"; dismiss() }
                }
                ForEach(available + ["silent"], id: \.self) { target in
                    Button(names[target] ?? target) { conversation.outputDestination = target; dismiss() }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Text("Choose one destination for your next answers. Availability is checked again when you send. Pair this iPad in Settings to use another destination.")
                    .font(.footnote)
            }
            .navigationTitle("Reply destination")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do {
                    let response = try await privateBody.request("api/ipad/destinations")
                    available = (response["destinations"] as? [String] ?? []).filter { ["ipad_display", "ipad_speech", "dot"].contains($0) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
