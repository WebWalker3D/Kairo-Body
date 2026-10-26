import SwiftUI

struct RestStatusCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
                .foregroundStyle(KairoTheme.mind)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.systems.freshRest?.state.rawValue.capitalized ?? "Rest state unavailable")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(KairoTheme.prose)
                if let rest = model.systems.freshRest {
                    Text("Reported \(rest.observedAt, style: .relative) ago")
                        .font(.system(size: 10)).foregroundStyle(KairoTheme.faint)
                } else {
                    Text(model.pairing.isPaired ? "Waiting for a fresh state" : "Owner pairing required")
                        .font(.system(size: 10)).foregroundStyle(KairoTheme.faint)
                }
            }
            Spacer()
            if model.systems.freshRest?.state != .awake, model.systems.freshRest != nil {
                Button { model.destination = .privateRoom } label: {
                    Image(systemName: "arrow.up.right").font(.caption)
                }.accessibilityLabel("Open private wake controls")
            }
        }
        .padding(18)
        .background(KairoTheme.mind.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(KairoTheme.mind.opacity(0.14)))
    }
    private var symbol: String {
        switch model.systems.freshRest?.state {
        case .awake: return "sun.horizon"
        case .sleeping: return "moon"
        case .dreaming: return "moon.stars"
        case nil: return "moon.dotted"
        }
    }
}

struct CapabilityCatalogue: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    private var filtered: [SystemCapability] {
        model.systems.capabilities.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kairo’s systems").font(.system(size: 27, design: .serif)).foregroundStyle(KairoTheme.prose)
                    Text("Capabilities published by Kairo. Enabling and authorization stay with the server.")
                        .font(.caption).foregroundStyle(KairoTheme.chrome)
                }
                Spacer()
                if !model.systems.unavailable {
                    Text("\(model.systems.capabilities.filter(\.enabled).count) enabled")
                        .font(.caption.monospaced()).foregroundStyle(KairoTheme.body)
                }
            }
            if model.systems.unavailable {
                PlaneCard {
                    Label(model.pairing.isPaired ? "Systems unavailable — waiting for a fresh response" : "Pair this iPad to view Kairo’s systems", systemImage: "network")
                        .font(.subheadline).foregroundStyle(KairoTheme.chrome)
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(KairoTheme.faint)
                    TextField("Find a capability", text: $search).foregroundStyle(KairoTheme.prose)
                }.padding(14).background(KairoTheme.plane, in: RoundedRectangle(cornerRadius: 14))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(filtered) { capability in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                Text(capability.name).font(.system(size: 14, weight: .medium)).foregroundStyle(KairoTheme.prose)
                                Spacer()
                                Text(capability.enabled ? "ENABLED" : "DISABLED")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(capability.enabled ? KairoTheme.body : KairoTheme.faint)
                            }
                            Text(capability.detail).font(.system(size: 12)).foregroundStyle(KairoTheme.chrome).lineLimit(5)
                            if !capability.prerequisites.isEmpty {
                                Text("Requires: " + capability.prerequisites.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(KairoTheme.faint).lineLimit(3)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(KairoTheme.plane.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(KairoTheme.hairline))
                    }
                }
                if filtered.isEmpty {
                    Text("No matching capabilities").font(.subheadline).foregroundStyle(KairoTheme.faint)
                }
            }
        }
    }
}
