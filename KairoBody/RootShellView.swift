import SwiftUI

struct RootShellView: View {
    @Environment(AppModel.self) private var model
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
                        .padding(.bottom, keyboardVisible ? 12 : 100)
                }
            }
            if model.systemsOpen && !model.body.screensaverActive && !needsSetup {
                SystemsPanel()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
        .onChange(of: model.destination) { _, destination in
            if destination == .look {
                model.destination = .stage
                model.systemsOpen = false
                model.lookPresented = true
            }
            model.updateSurfaceVisibility()
        }
        .onChange(of: model.lookPresented) { _, _ in model.updateSurfaceVisibility() }
        .onChange(of: model.body.screensaverActive) { _, asleep in
            if asleep { model.systemsOpen = false }
            model.updateSurfaceVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .animation(.easeInOut(duration: 0.8), value: model.body.screensaverActive)
        .sheet(isPresented: $needsSetup) {
            SetupView().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.lookPresented }, set: { model.lookPresented = $0 }),
               onDismiss: { model.updateSurfaceVisibility() }) {
            LookTogetherView().environment(model)
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
        case .look: PresenceStageView()
        case .privateRoom: PrivateRoomView()
        case .bodySurface: BodySurfaceView()
        case .settings: SettingsView()
        }
    }

    private var conversationError: String? { model.conversation.error }
}

/// Three daily places and one door to everything else. Private, Body and
/// Settings are used rarely on an appliance, so they live in the Systems
/// panel instead of crowding the rail.
private struct BottomRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppModel.Destination.primary) { item in
                railButton(title: item == .stage ? "Presence" : item.rawValue, icon: icon(item),
                           selected: model.destination == item && !model.systemsOpen) {
                    model.systemsOpen = false
                    if item == .look {
                        model.destination = .stage
                        model.lookPresented = true
                    } else { model.destination = item }
                }
            }
            railButton(title: "Systems", icon: "square.grid.2x2",
                       selected: model.systemsOpen || !model.destination.isPrimary) {
                model.systemsOpen.toggle()
            }
        }
        .padding(8)
        .frame(maxWidth: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(KairoTheme.hairline))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private func railButton(title: String, icon: String, selected: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button {
            model.body.noteUserActivity()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), action)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 21, weight: .light))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 60)
            .foregroundStyle(selected ? KairoTheme.primary : KairoTheme.dim)
            .background(selected ? KairoTheme.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// The secondary places as large tiles, then Kairo-wide state. It opens over
/// whatever screen is showing and closes when a place is chosen.
private struct SystemsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack {
                        Text("Systems").font(.system(size: 24, weight: .medium))
                        Spacer()
                        Button { close() } label: {
                            Image(systemName: "xmark").font(.system(size: 18)).frame(width: 48, height: 48)
                        }.accessibilityLabel("Close systems")
                    }
                    .foregroundStyle(KairoTheme.prose).padding(.horizontal, 20).padding(.top, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 10) {
                                tile(.privateRoom, title: "Private", icon: "lock", tint: KairoTheme.bond)
                                tile(.bodySurface, title: "Body", icon: "sensor.fill", tint: KairoTheme.body)
                                tile(.settings, title: "Settings", icon: "slider.horizontal.3", tint: KairoTheme.primary)
                            }
                            Eyebrow(text: "Across Kairo")
                            PresenceWorkspace()
                        }
                        .padding(16)
                    }.scrollIndicators(.hidden)
                }
                .frame(width: min(420, geometry.size.width - 32))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(KairoTheme.hairline))
                .padding(.trailing, 16).padding(.top, 12).padding(.bottom, 104)
            }
        }
    }

    private func tile(_ destination: AppModel.Destination, title: String, icon: String, tint: Color) -> some View {
        let selected = model.destination == destination
        return Button {
            model.body.noteUserActivity()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                model.destination = destination
                model.systemsOpen = false
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 24, weight: .light))
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 88)
            .foregroundStyle(selected ? tint : KairoTheme.prose)
            .background(RoundedRectangle(cornerRadius: 18).fill(tint.opacity(selected ? 0.18 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(selected ? 0.6 : 0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { model.systemsOpen = false }
    }
}

struct StatusChip: View {
    let label: String
    var color: Color = KairoTheme.body
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
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
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}
