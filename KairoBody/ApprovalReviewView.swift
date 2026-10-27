import SwiftUI

struct ApprovalReviewView: View {
    @Environment(AppModel.self) private var model
    let jobID: String
    @State private var reviewed: PendingApproval?
    @State private var showingReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = model.approvals.approval, item.jobID == jobID {
                Button {
                    reviewed = item
                    showingReview = true
                } label: {
                    Label("Review requested action", systemImage: "hand.raised")
                        .font(.subheadline.weight(.semibold))
                }.accessibilityIdentifier("reviewApproval")
            } else if !model.pairing.isPaired {
                Button("Open Private to pair this iPad") { model.destination = .privateRoom }
                    .font(.caption)
            } else {
                Button("Check pending approval") { Task { await model.approvals.refresh(jobID: jobID) } }
                    .font(.caption).disabled(model.approvals.busy)
            }
            if !model.approvals.status.isEmpty {
                Text(model.approvals.status).font(.caption).foregroundStyle(KairoTheme.chrome)
            }
            if let error = model.approvals.error {
                Text(error).font(.caption).foregroundStyle(KairoTheme.warn)
            }
        }
        .task(id: jobID) {
            guard model.isForeground, model.pairing.isPaired else { return }
            await model.approvals.refresh(jobID: jobID)
        }
        .sheet(isPresented: $showingReview) {
            if let item = reviewed {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Kairo paused this response to ask for permission.")
                            .font(.title3)
                        ScrollView {
                            Text(item.description).font(.body.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(item.truncated ? "The full request is unavailable. No decision can be sent."
                             : "Allow applies only to this request. It does not grant ongoing permission.")
                            .font(.subheadline).foregroundStyle(KairoTheme.chrome)
                        if model.approvals.approval != item {
                            Text("This request changed or is no longer pending. Close this panel and check again.")
                                .foregroundStyle(KairoTheme.warn)
                        }
                        HStack(spacing: 20) {
                            Button("Deny this request", role: .destructive) { decide(item, allow: false) }
                            Spacer()
                            Button("Allow once") { decide(item, allow: true) }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(item.truncated || model.approvals.busy || model.approvals.approval != item)
                    }
                    .padding(24)
                    .navigationTitle("Review action")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingReview = false } } }
                }.preferredColorScheme(.dark)
            }
        }
        .onChange(of: model.isForeground) { _, foreground in if !foreground { showingReview = false; reviewed = nil } }
        .onChange(of: model.pairing.isPaired) { _, paired in if !paired { showingReview = false; reviewed = nil } }
    }

    private func decide(_ item: PendingApproval, allow: Bool) {
        Task {
            await model.approvals.decide(item, allow: allow)
            showingReview = false
            reviewed = nil
        }
    }
}
