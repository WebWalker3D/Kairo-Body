import SwiftUI
import PhotosUI

/// "Look together": one image the person shares becomes server-side vision,
/// and its description attachment rides along with the next question — in the
/// Dot's own conversation when Echo following is on. The Dot can then talk
/// about what the iPad saw.
struct LookTogetherView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var question = ""
    @State private var work: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PlaneCard {
                    Eyebrow(text: "Shared image", color: KairoTheme.body)
                    if let jpeg = model.visual.previewJPEG, let image = UIImage(data: jpeg) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                            .cornerRadius(12)
                        Text(model.visual.source == .frontCamera
                             ? "Shared front-camera photo" : "Explicitly selected image")
                            .font(.caption).foregroundStyle(KairoTheme.chrome)
                        if let time = model.visual.observedAt {
                            Text("Shared at \(time.formatted())").font(.footnote).foregroundStyle(KairoTheme.faint)
                        }
                    } else {
                        Text("Choose one image to discuss with Kairo.")
                            .font(.subheadline).foregroundStyle(KairoTheme.dim)
                    }
                    HStack(spacing: 12) {
                        PhotosPicker("Choose image", selection: $selectedItem, matching: .images)
                            .font(.callout)
                            .disabled(busy)
                        Button("Front camera") { begin(source: .frontCamera) }
                            .disabled(busy)
                        Button("Clear", role: .destructive) {
                            cancel(); model.visual.clear(); selectedItem = nil; question = ""
                        }.disabled(model.visual.attachmentID == nil)
                    }
                    if busy { ProgressView("Preparing visual evidence…").tint(KairoTheme.primary) }
                    if let error = model.visual.error { Text(error).foregroundStyle(KairoTheme.danger).font(.caption) }
                }
                PlaneCard {
                    Eyebrow(text: "Question", color: KairoTheme.primary)
                    TextField("Ask Kairo about this image", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(KairoTheme.groundDeep))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KairoTheme.hairline))
                        .foregroundStyle(KairoTheme.prose)
                    Button {
                        guard model.conversation.canSubmit, let id = model.visual.sessionID else { return }
                        let question = self.question
                        let attachments = model.visual.attachmentIDs(for: id)
                        guard !attachments.isEmpty else { return }
                        let selection = model.visual.generation
                        model.visual.recordReply("", selection: selection)
                        Task {
                            let accepted = await model.conversation.send(question, attachmentIDs: attachments,
                                                                        attachmentSessionID: id)
                            if accepted, !model.conversation.reply.isEmpty {
                                model.visual.recordReply(model.conversation.reply, selection: selection)
                            }
                        }
                    } label: {
                        Label("Discuss this image", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(KairoTheme.primary.opacity(0.14)))
                            .overlay(Capsule().stroke(KairoTheme.primary.opacity(0.5)))
                            .foregroundStyle(KairoTheme.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !model.conversation.canSubmit
                              || model.visual.attachmentID == nil
                              || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || question.trimmingCharacters(in: .whitespacesAndNewlines).count > 16_000)
                    if model.conversation.isSending { ProgressView().tint(KairoTheme.primary) }
                    if !model.conversation.status.isEmpty {
                        Text(model.conversation.status).font(.caption).foregroundStyle(KairoTheme.chrome)
                    }
                    if model.conversation.hasPendingTurn && !model.conversation.isSending {
                        Button("Check pending reply in Conversation") { model.destination = .conversation }
                    }
                    if question.trimmingCharacters(in: .whitespacesAndNewlines).count > 16_000 {
                        Text("Questions can contain up to 16,000 characters.")
                            .font(.caption).foregroundStyle(KairoTheme.warn)
                    }
                    if !model.visual.discussionReply.isEmpty {
                        Text(model.visual.discussionReply).textSelection(.enabled)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(KairoTheme.prose)
                    }
                    Text("Only this selected image is attached. Clearing removes it from later questions.")
                        .font(.caption).foregroundStyle(KairoTheme.faint)
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 108)
            .frame(maxWidth: .infinity)
        }
        .background(KairoTheme.background)
        .onChange(of: selectedItem) { _, item in if item != nil { begin(source: .selectedImage) } }
        .onDisappear { if busy { cancel(); model.visual.clear() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Look together")
                .font(.system(size: 30, weight: .regular, design: .rounded))
                .foregroundStyle(KairoTheme.prose)
            Spacer()
        }
        .padding(.top, 14)
    }

    private func cancel() { work?.cancel(); work = nil; busy = false }

    private func begin(source: VisualSource) {
        cancel()
        model.visual.clear()
        let initial = model.visual.generation
        let item = selectedItem
        busy = true
        work = Task { @MainActor in
            var selection = initial
            defer { if model.visual.generation == selection { busy = false } }
            do {
                let sessionID = try await model.conversation.prepareVisualSession()
                try Task.checkCancellation()
                guard model.visual.generation == initial else { return }
                selection = model.visual.beginSelection(sessionID: sessionID)
                let observed = Date()
                let image: UIImage
                if source == .frontCamera {
                    image = try await model.body.captureSharedFrontPhoto()
                } else {
                    guard let bytes = try await item?.loadTransferable(type: Data.self),
                          bytes.count <= 20 * 1024 * 1024,
                          let decoded = UIImage(data: bytes) else {
                        throw ConversationError.jobFailed("Could not read the selected image.")
                    }
                    image = decoded
                }
                try Task.checkCancellation()
                try await model.conversation.uploadVisual(image, source: source, to: model.visual,
                    sessionID: sessionID, selection: selection, observedAt: observed)
            } catch is CancellationError {} catch {
                if model.visual.generation == selection { model.visual.fail(error.localizedDescription) }
            }
        }
    }
}
