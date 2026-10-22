import Foundation

/// What the screensaver shows while the body dozes: Kairo's live state, its
/// committed affect, whether anyone is near, and how the body itself is
/// connected — one card at a time, in a deliberate order. The state comes
/// from the ring mirror, which already fuses the Dot's live phase, the
/// server's presentation read, and this iPad's own acts, so the sleeping
/// body and the awake body never disagree about what Kairo is doing.
enum BodyAmbient {
    struct Card: Equatable {
        let title: String
        let detail: String?
    }

    static func phaseWord(_ phase: RingMirrorState.Phase) -> String {
        switch phase {
        case .idle: return "Quiet — online"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking with you"
        case .waiting: return "Waiting for you"
        case .reflecting: return "Working in the background"
        case .disconnected: return "Out of touch with Kairo"
        }
    }

    static func presenceCard(proximity: BodyProximity?, now: Date) -> Card {
        guard let proximity, proximity.isFresh(at: now) else {
            return Card(title: "No recent sight of you", detail: nil)
        }
        let age = Int(max(0, now.timeIntervalSince(proximity.observedAt)))
        return proximity.state == "near"
            ? Card(title: "Right beside you", detail: "seen \(age)s ago")
            : Card(title: "The room is quiet", detail: "seen \(age)s ago")
    }

    static func linkCard(presentation: GlobalBodyPresentation?, socketConnected: Bool,
                         now: Date) -> Card {
        guard socketConnected else {
            return Card(title: "Body link reconnecting", detail: nil)
        }
        let detail = presentation.map {
            "state seen \(Int(max(0, now.timeIntervalSince($0.observedAt))))s ago"
        } ?? "state feed has not reported lately"
        return Card(title: "Body link steady", detail: detail)
    }

    /// Ordered as the user reads them: what Kairo is doing, how it feels,
    /// whether anyone is here, and finally how the body is holding on.
    static func cards(ring: RingMirrorState, presentation: GlobalBodyPresentation?,
                      socketConnected: Bool, now: Date = Date()) -> [Card] {
        var stateDetail: String?
        if presentation?.phase == "queued" { stateDetail = "Something is queued up" }
        if presentation?.phase == "waiting" { stateDetail = "Kairo has something to say" }
        let state = Card(title: phaseWord(ring.phase), detail: stateDetail)

        let palette = ExpressionPalette.forState(ring.mood)
        let mood = Card(title: palette.name.capitalized,
                        detail: ring.presentationFresh ? "straight from Kairo's own read"
                                                       : "using the body's last known feel")

        return [state, mood,
                presenceCard(proximity: presentation?.proximity, now: now),
                linkCard(presentation: presentation, socketConnected: socketConnected, now: now)]
    }
}
