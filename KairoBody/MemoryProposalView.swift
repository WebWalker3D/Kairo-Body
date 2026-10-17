import Foundation
import SwiftUI

struct MemoryProposal {
    let id: String
    let hash: String
    let text: String
    let expiresAt: Date
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, id.hasPrefix("ipa_"), id.count <= 80,
              let hash = json["proposal_hash"] as? String, hash.count == 64,
              hash.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
              let note = json["note"] as? [String: Any], let text = note["text"] as? String,
              !text.isEmpty, text.count <= 12000,
              let raw = json["expires_at"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expiry = formatter.date(from: raw)
        if expiry == nil { formatter.formatOptions = [.withInternetDateTime]; expiry = formatter.date(from: raw) }
        guard let expiry, expiry > Date() else { return nil }
        self.id = id; self.hash = hash; self.text = text; expiresAt = expiry
    }
}

struct MemoryProposalView: View {
    @ObservedObject var client: PrivateBodyClient
    var body: some View {
        if let proposal = client.memoryProposal {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kairo proposes keeping this note").font(.headline)
                Text(proposal.text).textSelection(.enabled)
                Text("Keep gives permission for this exact note. Kairo then decides whether to adopt it. Dismiss preserves nothing.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Keep") { Task { await client.decideMemory("keep") } }
                    Button("Dismiss", role: .cancel) { Task { await client.decideMemory("dismiss") } }
                }.disabled(client.decidingMemory)
            }
        }
    }
}
