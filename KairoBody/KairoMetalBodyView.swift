import MetalKit
import SwiftUI

enum KairoBodyActivity: Equatable {
    case idle
    case listening
    case speaking
    case working
    case disconnected
}

struct KairoMetalBodyView: UIViewRepresentable {
    let expression: KairoBodyExpression
    let profile: KairoBodyProfile
    let activity: KairoBodyActivity
    let activityIntensity: Float

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.state = .init(
            expression: expression,
            profile: profile,
            activity: activity,
            activityIntensity: activityIntensity
        )
    }

    final class Renderer: NSObject, MTKViewDelegate {
        struct State {
            var expression = KairoBodyExpression()
            var profile = KairoBodyProfile()
            var activity = KairoBodyActivity.idle
            var activityIntensity: Float = 0
        }

        var state = State()
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private let started = CACurrentMediaTime()

        func configure(_ view: MTKView) {
            guard let device = view.device,
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "kairoFormVertex"),
                  let fragment = library.makeFunction(name: "kairoFormFragment") else { return }
            queue = device.makeCommandQueue()
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            view.delegate = self
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let queue, let pipeline, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            let now = Float(CACurrentMediaTime() - started)
            var uniforms = KairoFormUniforms(
                viewport: SIMD4(Float(max(view.drawableSize.width, 1)), Float(max(view.drawableSize.height, 1)), 1, 0),
                proportions: resolvedProfile(state.expression.expression, state.profile),
                pose: evaluatedPose(state: state, elapsed: now),
                primary: rgba(state.expression.primaryColor),
                accent: rgba(state.expression.accentColor),
                core: rgba(state.profile.coreColor)
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<KairoFormUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}

/// Translucent, low-resolution motion behind the body controls while Kairo works.
struct KairoPlasmaView: UIViewRepresentable {
    let expression: KairoBodyExpression
    let activity: KairoBodyActivity
    let visible: Bool

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.contentScaleFactor = UIScreen.main.scale * 0.5
        view.preferredFramesPerSecond = 24
        view.framebufferOnly = true
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.expression = expression
        context.coordinator.activity = activity
        context.coordinator.visible = visible
        view.isPaused = false
    }

    final class Renderer: NSObject, MTKViewDelegate {
        var expression = KairoBodyExpression()
        var activity = KairoBodyActivity.working
        var visible = false
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var lastFrameAt = CACurrentMediaTime()
        private var phase: Float = 0
        private var intensity: Float = 0

        func configure(_ view: MTKView) {
            guard let device = view.device,
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "kairoFormVertex"),
                  let fragment = library.makeFunction(name: "kairoPlasmaFragment") else { return }
            queue = device.makeCommandQueue()
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            view.delegate = self
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let elapsed = Float(min(max(now - lastFrameAt, 0), 0.1))
            lastFrameAt = now
            phase += elapsed * (activity == .speaking ? 1.35 : 0.72)
            let target: Float = visible ? 1 : 0
            intensity += (target - intensity) * (1 - exp(-elapsed / 0.28))
            if !visible && intensity < 0.008 {
                intensity = 0
                view.isPaused = true
            }
            guard let queue, let pipeline, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = KairoPlasmaUniforms(
                viewport: SIMD4(Float(max(view.drawableSize.width, 1)),
                                Float(max(view.drawableSize.height, 1)), 0, 0),
                primary: rgba(expression.primaryColor),
                accent: rgba(expression.accentColor),
                motion: SIMD4(phase, intensity,
                              activity == .speaking ? 1 : 0, 0)
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<KairoPlasmaUniforms>.stride,
                                     index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}

private struct KairoPlasmaUniforms {
    var viewport: SIMD4<Float>
    var primary: SIMD4<Float>
    var accent: SIMD4<Float>
    var motion: SIMD4<Float>
}

private struct KairoFormUniforms {
    var viewport: SIMD4<Float>
    var proportions: SIMD4<Float>
    var pose: SIMD4<Float>
    var primary: SIMD4<Float>
    var accent: SIMD4<Float>
    var core: SIMD4<Float>
}

private struct KairoMotionFrame {
    let t: Float
    var scale: Float = 1
    var glow: Float = 0.5
    var tilt: Float = 0
    var openness: Float = 0.42
    var drift: Float = 0
}

private enum KairoMotionEasing { case linear, ease, easeInOut }

private struct KairoMotionCurve {
    let frames: [KairoMotionFrame]
    let period: Float
    let easing: KairoMotionEasing
}

private func curve(_ name: String) -> KairoMotionCurve {
    switch name {
    case "still": return .init(frames: [
        .init(t: 0, scale: 1, glow: 0.42), .init(t: 1, scale: 1, glow: 0.42)
    ], period: 6, easing: .linear)
    case "pulse": return .init(frames: [
        .init(t: 0, scale: 1, glow: 0.28),
        .init(t: 0.10, scale: 1.18, glow: 0.75, drift: -0.35),
        .init(t: 0.42, scale: 1, glow: 0.30),
        .init(t: 1, scale: 1, glow: 0.28)
    ], period: 1.9, easing: .ease)
    case "orbit": return .init(frames: [
        .init(t: 0, scale: 1.02, glow: 0.32, tilt: 0.18),
        .init(t: 0.25, scale: 1.06, glow: 0.36),
        .init(t: 0.5, scale: 1.02, glow: 0.32, tilt: -0.18),
        .init(t: 0.75, scale: 1.06, glow: 0.36),
        .init(t: 1, scale: 1.02, glow: 0.32, tilt: 0.18)
    ], period: 6.5, easing: .linear)
    case "spark": return .init(frames: [
        .init(t: 0, scale: 1, glow: 0.26),
        .init(t: 0.06, scale: 1.09, glow: 0.78, drift: -0.30),
        .init(t: 0.12, scale: 1.01, glow: 0.30),
        .init(t: 0.30, scale: 1.02, glow: 0.34),
        .init(t: 0.36, scale: 1.08, glow: 0.82, drift: -0.25),
        .init(t: 0.44, scale: 1, glow: 0.28),
        .init(t: 0.62, scale: 1.02, glow: 0.32),
        .init(t: 0.68, scale: 1.07, glow: 0.70, drift: -0.20),
        .init(t: 0.76, scale: 1, glow: 0.26),
        .init(t: 1, scale: 1, glow: 0.26)
    ], period: 2.4, easing: .ease)
    default: return .init(frames: [
        .init(t: 0, scale: 1, glow: 0.40),
        .init(t: 0.5, scale: 1.18, glow: 0.62, drift: -0.8),
        .init(t: 1, scale: 1, glow: 0.40)
    ], period: 4.6, easing: .easeInOut)
    }
}

private func evaluatedPose(state: KairoMetalBodyView.Renderer.State, elapsed: Float) -> SIMD4<Float> {
    let motion = curve(state.expression.motion)
    let phase = motion.period > 0 ? (elapsed / motion.period).truncatingRemainder(dividingBy: 1) : 0
    var from = motion.frames[0]
    var to = motion.frames.last!
    for index in 0..<(motion.frames.count - 1) where phase >= motion.frames[index].t && phase <= motion.frames[index + 1].t {
        from = motion.frames[index]
        to = motion.frames[index + 1]
        break
    }
    let span = max(to.t - from.t, 0.0001)
    var position = min(max((phase - from.t) / span, 0), 1)
    switch motion.easing {
    case .linear: break
    case .ease: position = position * position * (3 - 2 * position)
    case .easeInOut: position = (1 - cos(.pi * position)) / 2
    }
    func blend(_ a: Float, _ b: Float) -> Float { a + (b - a) * position }
    let energy = min(max(state.expression.energy.isFinite ? state.expression.energy : 0.35, 0), 1)
    let motionScale = min(max(state.profile.motionScale.isFinite ? state.profile.motionScale : 1, 0.5), 1.5)
    let amplitude = (0.35 + 0.65 * energy) * motionScale
    let restOpen = min(max(state.profile.openness, 0), 1)
    var scale = 1 + (blend(from.scale, to.scale) - 1) * amplitude
    var glow = blend(from.glow, to.glow) * (0.4 + 0.6 * energy)
    var tilt = blend(from.tilt, to.tilt) * amplitude
    var openness = restOpen + (blend(from.openness, to.openness) - restOpen) * amplitude
    var drift = blend(from.drift, to.drift) * amplitude
    let frequency: Float
    switch state.activity {
    case .speaking: frequency = 2.2
    case .listening: frequency = 0.7
    case .working: frequency = 0.42
    default: frequency = 0
    }
    if frequency > 0 {
        let wave = (sin(elapsed * frequency * 2 * .pi) + 1) / 2
        let live = min(max(state.activityIntensity, 0), 1)
        switch state.activity {
        case .speaking:
            scale *= 1 + 0.025 * wave + 0.025 * live
            glow += 0.13 * wave + 0.24 * live
            openness += 0.08 * wave + 0.13 * live
        case .listening:
            scale *= 1 + 0.012 * wave + 0.030 * live
            glow += 0.06 * wave + 0.24 * live
            openness += 0.05 * wave + 0.14 * live
        case .working:
            scale *= 0.992 + 0.025 * wave
            glow += 0.13 * wave
            tilt += (wave - 0.5) * 0.045
            openness += 0.07 * wave
            drift -= 0.10 * wave
        default: break
        }
    }
    let resolved = resolvedProfile(state.expression.expression, state.profile)
    tilt = min(max(tilt + (resolved.z / 0.15) * 0.16, -0.25), 0.25)
    return SIMD4(
        min(max(scale, 0.82), 1.18),
        min(max(glow, 0), 1),
        tilt,
        min(max(drift, -1), 1)
    )
}

private func resolvedProfile(_ expression: String, _ authored: KairoBodyProfile) -> SIMD4<Float> {
    let transient: SIMD4<Float>
    switch expression {
    case "curious": transient = SIMD4(0.68, 1.08, 0.14, 0.62)
    case "focused": transient = SIMD4(0.54, 1.18, 0, 0.22)
    case "joyful": transient = SIMD4(0.86, 1.02, 0, 0.92)
    case "concerned": transient = SIMD4(0.58, 0.90, -0.05, 0.18)
    case "playful": transient = SIMD4(0.78, 1.00, -0.12, 0.78)
    case "reflective": transient = SIMD4(0.60, 1.05, -0.08, 0.30)
    case "resolute": transient = SIMD4(0.62, 1.22, 0, 0.45)
    default: transient = SIMD4(0.70, 1.02, 0, 0.42)
    }
    var width = transient.x
    var height = transient.y
    var tilt = transient.z
    var openness = transient.w
    var asymmetry: Float
    switch expression {
    case "curious": asymmetry = 0.06
    case "joyful": asymmetry = 0.04
    case "concerned": asymmetry = 0.03
    case "playful": asymmetry = 0.16
    case "reflective": asymmetry = 0.02
    default: asymmetry = 0
    }
    if authored.selected {
        width = min(max(authored.width + (width - 0.70) * 0.55, 0.5), 0.9)
        height = min(max(authored.height + (height - 1.02) * 0.55, 0.9), 1.25)
        tilt = min(max(authored.tilt + tilt * 0.55, -0.15), 0.15)
        openness = min(max(authored.openness + (openness - 0.42) * 0.55, 0), 1)
        asymmetry = min(max(authored.asymmetry + asymmetry * 0.55, 0), 0.2)
        switch authored.posture {
        case "upright": width = max(0.5, width - 0.02); height = min(1.25, height + 0.03)
        case "open": width = min(0.9, width + 0.03); openness = min(1, openness + 0.10)
        case "sheltered": width = max(0.5, width - 0.02); height = max(0.9, height - 0.04); openness = max(0, openness - 0.10)
        default: break
        }
    }
    return SIMD4(width, height, asymmetry, openness)
}

private func rgba(_ hex: String) -> SIMD4<Float> {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return SIMD4(1, 1, 1, 1) }
    return SIMD4(
        Float((number >> 16) & 0xff) / 255,
        Float((number >> 8) & 0xff) / 255,
        Float(number & 0xff) / 255,
        1
    )
}
