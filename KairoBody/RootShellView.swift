import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel
    @State private var needsSetup = !AppConfig.hasMinimumProvisioning
        && !UserDefaults.standard.bool(forKey: "setupDeferred")

    var body: some View {
        ZStack {
            KairoTheme.background
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.body.screensaverActive {
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
        HStack(spacing: 8) {
            ForEach(AppModel.Destination.allCases) { item in
                Button {
                    model.destination = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon(item))
                            .font(.system(size: 17, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.6)
                    }
                    .frame(width: 78, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(model.destination == item ? KairoTheme.primary.opacity(0.14) : KairoTheme.plane.opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(model.destination == item ? KairoTheme.primary.opacity(0.5) : KairoTheme.hairline,
                                    lineWidth: 1)
                    )
                    .foregroundStyle(model.destination == item ? KairoTheme.primary : KairoTheme.chrome)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.bottom, 6)
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
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(KairoTheme.plane.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(KairoTheme.hairline, lineWidth: 1))
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
