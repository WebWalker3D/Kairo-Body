import SwiftUI
import PhotosUI

struct SharedVisualView: View {
    @ObservedObject var context: SharedVisualContext
    @ObservedObject var conversation: ConversationClient
    @ObservedObject var settings: AppSettings
    let captureFront: () async throws -> UIImage
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedItem: PhotosPickerItem?
    @State private var work: Task<Void, Never>?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Shared image") {
                    if let jpeg = context.previewJPEG, let image = UIImage(data: jpeg) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                        Text(context.source == .frontCamera ? "Shared front-camera photo" : "Explicitly selected image")
                        if let time = context.observedAt { Text("Shared at \(time.formatted())").font(.caption) }
                    } else { Text("Choose one image to discuss with Kairo.") }
                    PhotosPicker("Select or replace image", selection: $selectedItem, matching: .images)
                        .disabled(busy)
                    Button("Take front-camera photo") { begin(source: .frontCamera) }
                        .disabled(busy || scenePhase != .active)
                    Button("Clear image") { cancel(); context.clear(); selectedItem = nil }
                    if busy { ProgressView("Preparing visual evidence…") }
                    if let error = context.error { Text(error).foregroundStyle(.red) }
                }
                Section("Question") {
                    TextField("Ask Kairo about this image", text: $context.question, axis: .vertical)
                    Button("Discuss this image") {
                        guard let id = context.sessionID else { return }
                        let question = context.question
                        let attachments = context.attachmentIDs(for: id)
                        guard !attachments.isEmpty else { return }
                        Task { await conversation.send(question, attachmentIDs: attachments, attachmentSessionID: id) }
                    }.disabled(busy || conversation.isSending || context.attachmentID == nil || context.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = conversation.error { Text(error).foregroundStyle(.red) }
                    if !conversation.reply.isEmpty { Text(conversation.reply).textSelection(.enabled) }
                    Text("Only this selected image is attached. A fresh look around is a separate request. Clearing removes it from later questions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Look together")
        }
        .onChange(of: selectedItem) { _, item in if item != nil { begin(source: .selectedImage) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel(); context.clear() } }
        .onChange(of: settings.followEcho) { _, _ in cancel(); context.clear() }
        .onChange(of: settings.agentWorkspaceID) { _, _ in cancel(); context.clear() }
        .onChange(of: settings.echoSessionID) { _, _ in cancel(); context.clear() }
        .onDisappear { if busy { cancel(); context.clear() } }
    }

    private func cancel() { work?.cancel(); work = nil; busy = false }
    private func begin(source: VisualSource) {
        cancel()
        context.clear()
        let initial = context.generation
        let item = selectedItem
        busy = true
        work = Task { @MainActor in
            var selection = initial
            defer { if context.generation == selection { busy = false } }
            do {
                let sessionID = try await conversation.prepareVisualSession()
                try Task.checkCancellation()
                guard context.generation == initial else { return }
                selection = context.beginSelection(sessionID: sessionID)
                let observed = Date()
                let image: UIImage
                if source == .frontCamera {
                    image = try await captureFront()
                } else {
                    guard let bytes = try await item?.loadTransferable(type: Data.self), bytes.count <= 20 * 1024 * 1024,
                          let decoded = UIImage(data: bytes) else {
                        throw ConversationError.jobFailed("Could not read the selected image.")
                    }
                    image = decoded
                }
                try Task.checkCancellation()
                try await conversation.uploadVisual(image, source: source, to: context,
                    sessionID: sessionID, selection: selection, observedAt: observed)
            } catch is CancellationError {} catch {
                if context.generation == selection { context.fail(error.localizedDescription) }
            }
        }
    }
}
