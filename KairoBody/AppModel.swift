import Foundation
import AVFoundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    var settings = AppSettings()
    let sensors = SensorManager()
    private lazy var speech = SpeechService(settings: settings)
    private let camera = CameraCaptureService()
    lazy var client = BodyClient(settings: settings, sensors: sensors, speech: speech, camera: camera)
    lazy var conversation: ConversationClient = {
        let value = ConversationClient(settings: settings, speech: speech)
        value.prepareOutput = { [weak self] destination in try await self?.surfaceDelivery.prepare(destination) }
        value.deliverOutput = { [weak self] job, destination in await self?.surfaceDelivery.deliver(jobID: job, destination: destination) }
        value.stopOutput = { [weak self] in self?.surfaceDelivery.stop() }
        return value
    }()
    lazy var surfaceDelivery = SurfaceDeliveryClient(
        request: { [weak self] path, body in
            guard let self else { throw CancellationError() }
            return try await self.privateBody.request(path, body: body)
        }, display: { [weak self] text in self?.conversation.applyDeliveredAnswer(text) },
        speak: { [weak self] text, onEvent in self?.speech.speak(text, onEvent: onEvent) ?? false },
        stopSpeech: { [weak self] in self?.speech.stop() })
    lazy var echoConversation = EchoConversationClient(agentToken: { [weak self] in self?.settings.agentToken ?? "" },
        ownerCredential: { PrivateBodyClient.ownerCredential() })
    let echoPlayback = EchoActivityClient()
    let voice = VoiceInputService()
    let sharedVisual = SharedVisualContext()
    lazy var privateBody = PrivateBodyClient(settings: settings)
    lazy var invitations = InvitationClient(request: { [weak self] path, body in
        guard let self else { throw CancellationError() }
        return try await self.privateBody.request(path, body: body)
    })

    @Published var settingsPresented = false
    @Published var tokenDraft = ""
    @Published var agentTokenDraft = ""

    init() {
        tokenDraft = settings.bearerToken
        agentTokenDraft = settings.agentToken
    }

    func updateEcho(foreground: Bool) {
        let enabled = foreground && settings.followEcho && EchoBinding.sessionID(settings.echoSessionID) != nil
        echoConversation.followAllSurfaces(foreground: foreground)
        echoPlayback.follow(token: settings.agentToken, foreground: enabled)
    }

    func captureSharedFrontPhoto() async throws -> UIImage {
        try await client.captureSharedFrontPhoto()
    }

    func saveToken() {
        settings.bearerToken = tokenDraft
        settings.agentToken = agentTokenDraft
        updateEcho(foreground: true)
    }
}
