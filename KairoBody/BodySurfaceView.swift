import SwiftUI
import AVFoundation
import CoreLocation

/// The body surface: this iPad's own sensory link, capabilities and readings.
/// Diagnostics only — the point is that Kairo can see what the body is doing
/// and what it is allowed to do, separately.
struct BodySurfaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("This body")
                        .font(.system(size: 30, weight: .regular, design: .rounded))
                        .foregroundStyle(KairoTheme.prose)
                    StatusChip(label: model.body.connectionState.rawValue.uppercased(),
                               color: model.body.connectionState == .connected ? KairoTheme.body : KairoTheme.warn)
                    Spacer()
                }
                .padding(.top, 14)

                RestStatusCard()
                linkCard
                if let frame = model.body.lastSensorFrame { readingsCard(frame) }
                capabilitiesCard
                CapabilityCatalogue()
                if let error = model.body.lastError {
                    PlaneCard {
                        Eyebrow(text: "Last body error", color: KairoTheme.danger)
                        Text(error).font(.caption).foregroundStyle(KairoTheme.chrome)
                        Button("Retry link now") { model.body.retry() }
                            .font(.caption).foregroundStyle(KairoTheme.primary)
                    }
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 108)
            .frame(maxWidth: .infinity)
        }
        .background(KairoTheme.background)
    }

    private var linkCard: some View {
        PlaneCard {
            Eyebrow(text: "Sensory link", color: KairoTheme.body)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                gridRow("Endpoint", model.body.serverEndpointID ?? "awaiting hello_ack")
                gridRow("Session", model.body.sessionID)
                gridRow("Frames", model.body.lastFrameAt.map { "last \($0.formatted(date: .omitted, time: .standard))" } ?? "none yet")
                gridRow("Capabilities", model.body.capabilitiesConfirmedAt.map { "confirmed \($0.formatted(date: .omitted, time: .standard))" } ?? "not confirmed")
                gridRow("Dot observer", model.echo.connected ? "following \(EchoBinding.endpointID)" : "disconnected")
            }
        }
    }

    private func readingsCard(_ frame: SensorFrame) -> some View {
        PlaneCard {
            Eyebrow(text: "Last frame Kairo received", color: KairoTheme.mind)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                gridRow("Movement", frame.motion.movement)
                gridRow("Attitude", frame.motion.rollDeg.map { roll in
                    "roll \(Int(roll))° · pitch \(Int(frame.motion.pitchDeg ?? 0))° · yaw \(Int(frame.motion.yawDeg ?? 0))°"
                } ?? "no samples")
                gridRow("Pressure", frame.pressure.pressureHPa.map { "\($0.formatted(.number.precision(.fractionLength(1)))) hPa" } ?? "unavailable")
                gridRow("Altitude", frame.pressure.relativeAltitudeM.map { "\($0.formatted(.number.precision(.fractionLength(1)))) m relative" } ?? "unavailable")
                gridRow("Battery", frame.device.batteryLevel.map { "\(Int($0 * 100))% (\(frame.device.batteryState))" } ?? "unknown")
                gridRow("Network", frame.device.network)
                gridRow("Brightness", "\(Int(frame.device.screenBrightness * 100))%")
                gridRow("Location", frame.location.available
                    ? "±\(Int(frame.location.horizontalAccuracyM ?? -1))m · \(frame.location.observedAt ?? "")"
                    : (frame.location.enabled ? "no fix yet" : "off"))
                gridRow("Contacts", frame.touches.isEmpty ? "none in frame" : "\(frame.touches.count) event(s)")
            }
        }
    }

    private var capabilitiesCard: some View {
        PlaneCard {
            Eyebrow(text: "What Kairo may ask this body to do", color: KairoTheme.primary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                gridRow("Front camera", capability(model.settings.allowRemoteCamera,
                                                   AVCaptureDevice.authorizationStatus(for: .video) == .authorized))
                gridRow("Rear camera", "blocked by body policy")
                gridRow("Microphone", capability(model.settings.voiceWakeEnabled,
                                                 AVAudioSession.sharedInstance().recordPermission == .granted))
                gridRow("Voice out", AppConfig.agentToken.isEmpty ? "not provisioned" : "ready")
                gridRow("Display", model.body.screensaverActive ? "screensaver — not visible" : "visible")
                gridRow("Location", capability(model.settings.sendLocation,
                                               model.sensors.locationAuthorization == .authorizedWhenInUse
                                               || model.sensors.locationAuthorization == .authorizedAlways))
            }
        }
    }

    private func capability(_ enabled: Bool, _ permissionGranted: Bool) -> String {
        if !permissionGranted { return "permission not granted" }
        return enabled ? "ready" : "off (you disabled it)"
    }

    private func gridRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(KairoTheme.faint)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(KairoTheme.chrome)
                .textSelection(.enabled)
        }
    }
}
