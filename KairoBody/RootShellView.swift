import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel
    @State private var needsSetup = !AppConfig.hasMinimumProvisioning
        && !UserDefaults.standard.bool(forKey: "setupDeferred")

    @State private var keyboardVisible = false

    var body: some View {
        ZStack {
            KairoTheme.background
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.body.screensaverActive, !needsSetup, let text = model.stageDisplayText {
                VStack {
                    Spacer()
                    SurfaceOutputView(text: text)
                        .padding(.bottom, keyboardVisible ? 12 : 88)
                }
            }
            if !model.body.screensaverActive && !keyboardVisible {
                VStack {
                    Spacer()
                    BottomRail()
                }
            }
            if model.body.screensaverActive {
                ScreensaverOverlay()
                    .transition(.opacity)
            }
        }
        .tint(KairoTheme.primary)
        .onAppear { model.setSurfaceVisibility(!needsSetup) }
        .onDisappear { model.setSurfaceVisibility(false) }
        .onChange(of: model.pairing.isPaired) { _, _ in model.pairingChanged() }
        .onChange(of: needsSetup) { _, value in model.setSurfaceVisibility(!value) }
        .onChange(of: model.destination) { _, _ in model.updateSurfaceVisibility() }
        .onChange(of: model.body.screensaverActive) { _, _ in model.updateSurfaceVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .animation(.easeInOut(duration: 0.8), value: model.body.screensaverActive)
        .sheet(isPresented: $needsSetup) {
            SetupView().environmentObject(model)
        }
        .alert("Kairo", isPresented: Binding(
            get: { conversationError != nil },
            set: { if !$0 { model.conversation.clearError() } })) {
            Button("OK") { model.conversation.clearError() }
        } message: {
            Text(conversationError ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.destination {
        case .stage: PresenceStageView()
        case .conversation: TranscriptView()
        case .look: LookTogetherView()
        case .privateRoom: PrivateRoomView()
        case .bodySurface: BodySurfaceView()
        case .settings: SettingsView()
        }
    }

    private var conversationError: String? { model.conversation.error }
}

private struct BottomRail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Destination.allCases) { item in
                Button {
                    model.body.noteUserActivity()
                    withAnimation(.easeOut(duration: 0.2)) { model.destination = item }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon(item)).font(.system(size: 18, weight: .light))
                        Text(item == .stage ? "Presence" : item.rawValue)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).frame(height: 51)
                    .foregroundStyle(model.destination == item ? KairoTheme.primary : KairoTheme.chrome)
                    .background(model.destination == item ? KairoTheme.primary.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 15))
                    .overlay(alignment: .bottom) {
                        if model.destination == item {
                            Capsule().fill(KairoTheme.primary).frame(width: 15, height: 2).offset(y: 3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.destination == item ? .isSelected : [])
            }
        }
        .padding(8)
        .frame(maxWidth: 590)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(KairoTheme.hairline))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private func icon(_ item: AppModel.Destination) -> String {
        switch item {
        case .stage: return "circle.dotted"
        case .conversation: return "bubble.left.and.bubble.right"
        case .look: return "eye"
        case .privateRoom: return "lock"
        case .bodySurface: return "sensor.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct StatusChip: View {
    let label: String
    var color: Color = KairoTheme.body
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.7)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        .foregroundStyle(color)
    }
}

struct PlaneCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22).fill(KairoTheme.plane.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(KairoTheme.hairline, lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = KairoTheme.faint
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}
