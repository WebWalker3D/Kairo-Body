import SwiftUI

struct InvitationView: View {
    @ObservedObject var client: InvitationClient
    let onAccept: (String) -> Void
    var body: some View {
        if let invitation = client.invitation {
            VStack(alignment: .leading, spacing: 10) {
                Label("Kairo invites you", systemImage: "bubble.left")
                    .font(.headline)
                Text(invitation.text)
                HStack {
                    Button("Let's talk") { Task { if let question = await client.accept() { onAccept(question) } } }
                        .disabled(!client.canRespond)
                    Button("Dismiss") { Task { await client.dismiss() } }
                }
                Text("You can respond when you want. This does not enable any sensors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .task(id: invitation.id) { await client.markDisplayed() }
        }
    }
}
