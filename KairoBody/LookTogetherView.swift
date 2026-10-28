import AVFoundation
import SwiftUI
import PhotosUI

/// A local sharing sheet over the current conversation, not a separate chat.
struct LookTogetherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var observedAt = Date()
    @State private var error: String?
    @State private var loading = false
    @State private var useCamera = false

    var body: some View {
        NavigationStack {
            Group {
                if useCamera {
                    SharedCameraView { image, observed in attach(image, source: .frontCamera, at: observed) }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            Text("Show Kairo something")
                                .font(.title2)
                            Text("Your photo stays on this iPad until you send your message.")
                                .foregroundStyle(.secondary)
                            if let photo {
                                Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 380)
                                Button("Attach photo") { attach(photo, source: .selectedImage, at: observedAt) }
                                    .buttonStyle(.borderedProminent)
                            }
                            Button { useCamera = true } label: {
                                Label("Front camera", systemImage: "camera")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered)
                            PhotosPicker(selection: $selectedItem, matching: .images) {
                                Label(photo == nil ? "Choose image" : "Choose another image", systemImage: "photo")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered).disabled(loading)
                            if loading { ProgressView("Opening image…") }
                            if let error { Text(error).foregroundStyle(.red) }
                        }.padding(24)
                    }
                }
            }
            .navigationTitle("Look together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: selectedItem) {
                guard let item = selectedItem else { return }
                loading = true; error = nil; photo = nil
                defer { loading = false }
                do {
                    guard let bytes = try await item.loadTransferable(type: Data.self),
                          bytes.count <= 20 * 1024 * 1024, let image = UIImage(data: bytes) else {
                        throw ConversationError.jobFailed("Could not read the selected image.")
                    }
                    try Task.checkCancellation()
                    photo = image; observedAt = Date()
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        }
        .interactiveDismissDisabled(loading)
    }

    private func attach(_ image: UIImage, source: VisualSource, at date: Date) {
        do {
            try model.imageDraft.select(image, source: source, observedAt: date)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SharedCameraView: View {
    @Environment(AppModel.self) private var model
    let attach: (UIImage, Date) -> Void
    @State private var camera = SharedCameraSession()
    @State private var session: AVCaptureSession?
    @State private var reservation: UUID?
    @State private var photo: UIImage?
    @State private var observedAt = Date()
    @State private var error: String?
    @State private var capturing = false
    @State private var closed = false

    var body: some View {
        VStack(spacing: 16) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Retake") { self.photo = nil; error = nil }
                    Spacer()
                    Button("Attach photo") { attach(photo, observedAt) }.buttonStyle(.borderedProminent)
                }
            } else if let session {
                FrontCameraPreview(session: session)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Live front-camera preview")
                Button {
                    capturing = true
                    let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                        .first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation ?? .portrait
                    Task { @MainActor in
                        defer { capturing = false }
                        do {
                            let image = try await camera.capture(orientation: AVCaptureVideoOrientation(interfaceOrientation: orientation))
                            guard !closed, model.isForeground else { return }
                            let capturedAt = Date()
                            await camera.stop()
                            guard !closed, model.isForeground else { return }
                            self.session = nil
                            observedAt = capturedAt; photo = image
                        } catch is CancellationError {} catch { self.error = error.localizedDescription }
                    }
                } label: { Label(capturing ? "Capturing…" : "Capture photo", systemImage: "camera.fill") }
                    .buttonStyle(.borderedProminent).disabled(capturing)
            } else if error == nil {
                ProgressView("Opening front camera…").frame(maxHeight: .infinity)
            }
            if let error {
                Text(error).foregroundStyle(.red)
                if session == nil { Button("Try camera again") { self.error = nil } }
            }
            Text("Preview stays on this iPad. Attach a photo, then send it with your message.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .task { await runCamera() }
        .onDisappear { closed = true }
    }

    /// One lifecycle task owns startup and teardown, including permission
    /// alerts. Transient inactivity pauses the camera without closing review.
    @MainActor private func runCamera() async {
        while !Task.isCancelled && !closed {
            if !model.isForeground {
                await closeCamera()
            } else if photo == nil, session == nil, error == nil, !capturing {
                do {
                    if reservation == nil { reservation = try await model.body.reserveSharedCamera() }
                    let started = try await camera.start()
                    try Task.checkCancellation()
                    if model.isForeground && !closed { session = started }
                    else { await closeCamera() }
                } catch {
                    await closeCamera()
                    if !(error is CancellationError), !Task.isCancelled, !closed {
                        self.error = error.localizedDescription
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { break }
        }
        await closeCamera()
    }

    @MainActor private func closeCamera() async {
        await camera.stop()
        session = nil
        if let id = reservation { model.body.releaseSharedCamera(id); reservation = nil }
    }
}

struct SharedImageAttachment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let photo = model.imageDraft.photo, let image = photo.image {
            HStack(spacing: 12) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.conversation.isSending ? "Sharing photo…" : "Photo attached")
                    Text("Sent with your next message").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.imageDraft.remove(ifMatching: photo.id) } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("Remove attached photo").disabled(model.conversation.isSending)
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("sharedImageAttachment")
        }
    }
}
