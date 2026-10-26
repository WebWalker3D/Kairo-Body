import SwiftUI

/// A root-level surface so a claimed answer is visible on every destination.
/// Its mounted content acknowledges display; merely setting model text does not.
struct SurfaceOutputView: View {
    @EnvironmentObject private var model: AppModel
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle").foregroundStyle(KairoTheme.primary)
                Eyebrow(text: "Kairo · here with you", color: KairoTheme.primary)
                Spacer()
                Button { model.clearStageDisplay() } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }.buttonStyle(.plain).foregroundStyle(KairoTheme.chrome)
                    .accessibilityLabel("Dismiss Kairo's display")
            }
            ScrollView {
                Text(text).font(.system(size: 20, design: .rounded)).lineSpacing(5)
                    .foregroundStyle(KairoTheme.prose).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 190)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .background(KairoTheme.groundDeep.opacity(0.94), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(KairoTheme.primary.opacity(0.35)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .frame(maxWidth: 680)
        .padding(.horizontal, 22)
        .task(id: model.stageDisplayID) { model.acknowledgeStageDisplay(text) }
        .accessibilityIdentifier("kairoSurfaceOutput")
    }
}
