import MetalKit
import SwiftUI

/// What the renderer draws right now. Everything here is derived from server
/// signals (Dot stream, presentation, local acts) — never invented.
struct RingRenderState: Equatable {
    var moodPrimary: SIMD3<Float> = SIMD3<Float>(0.372, 0.702, 1.0)   // #5fb3ff
    var moodAccent: SIMD3<Float> = SIMD3<Float>(0.902, 0.973, 1.0)    // #e6f8ff
    var coreColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    var emitterLevels: [Float] = []           // exactly 12 values
    var breath: Float = 0.35
    var energy: Float = 0.5
    var arousal: Float = 0.3
    var intensity: Float = 0.9
    var sleeping = false
    var fade: Float = 1
    // What Kairo is doing, and how the committed mood likes to move. The
    // shader animates both with the 1.0.x vocabulary; a speaking body where
    // the Dot's waveform is stale still visibly speaks.
    var activity: RingActivity = .idle
    var activityLevel: Float = 0
    var motion: RingMotion = .breathe
}

enum RingActivity: Int {
    case idle = 0, listening, speaking, thinking
}

enum RingMotion: Int {
    case breathe = 0, orbit, pulse, spark
}

struct KairoRingMetalView: UIViewRepresentable {
    let state: RingRenderState
    var framesPerSecond: Int = 30
    var reduceMotion = false
    var contact: CGPoint? = nil
    /// A covered or sleeping surface draws nothing: the stage stays mounted
    /// under the screensaver, and an unseen 24,000-point field is pure heat.
    var paused = false

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.contentScaleFactor = min(UIScreen.main.scale, 1.5)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        // Blend light in linear space, then encode for the display. Treating
        // linear shader values as sRGB made the field unnaturally dark.
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = framesPerSecond
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        view.isPaused = paused
        context.coordinator.reducedMotion = reduceMotion
        // On release only the strength fades; the ripple stays where the
        // finger lifted instead of sliding toward the centre.
        let previous = context.coordinator.contactTarget
        context.coordinator.contactTarget = contact.map {
            SIMD4<Float>(Float($0.x * 2 - 1), Float(1 - $0.y * 2), 1, 0)
        } ?? SIMD4<Float>(previous.x, previous.y, 0, 0)
        context.coordinator.apply(state, size: view.bounds.size)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        var reducedMotion = false
        var contactTarget = SIMD4<Float>.zero
        private var contactCurrent = SIMD4<Float>.zero
        private var particlePipeline: MTLRenderPipelineState?
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var uniforms = KairoRingUniformsStorage()
        private var start = ProcessInfo.processInfo.systemUptime
        private var lastFrame: Double?
        private var target = RingRenderState()
        private var dynamics = TorusDynamics()
        private var size: CGSize = .zero
        private var needsRender = true

        func configure(_ view: MTKView) {
            guard let device = view.device,
                  let library = device.makeDefaultLibrary() else { return }
            queue = device.makeCommandQueue()
            guard let vertex = library.makeFunction(name: "kairoRingVertex"),
                  let fragment = library.makeFunction(name: "kairoRingFragment") else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { pipeline = try view.device?.makeRenderPipelineState(descriptor: descriptor) }
            catch { pipeline = nil }
            descriptor.vertexFunction = library.makeFunction(name: "kairoParticleVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "kairoParticleFragment")
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            do { particlePipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { particlePipeline = nil }
            view.delegate = self
        }

        func apply(_ state: RingRenderState, size: CGSize) {
            target = state
            self.size = size
            needsRender = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { self.size = size }

        func draw(in view: MTKView) {
            guard view.window != nil, let pipeline, let particlePipeline, let queue, let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            // This body runs on permanent duty without relaunch. The shader's
            // waves run on float32, and float32 loses resolution as its clock
            // grows: after a few days of uptime the motion quantizes, and a
            // few weeks in it degenerates. Wrapping at twelve hours keeps the
            // animation exact forever - the cost is one momentary phase skip
            // a day on an otherwise calm surface, far cheaper than the ring
            // quietly freezing on a shelf that never sleeps.
            let now = ProcessInfo.processInfo.systemUptime
            let dt = lastFrame.map { min(max(now - $0, 0), 0.1) } ?? 0
            lastFrame = now
            dynamics.advance(toward: TorusAppearance(primary: target.moodPrimary,
                accent: target.moodAccent, arousal: target.arousal, energy: target.energy),
                seconds: dt, reducedMotion: reducedMotion)
            var rendered = target
            rendered.moodPrimary = dynamics.current.primary
            rendered.moodAccent = dynamics.current.accent
            rendered.arousal = dynamics.current.arousal
            rendered.energy = dynamics.current.energy
            rendered.breath = 0.18 + rendered.arousal * 0.14
            uniforms.apply(rendered, viewport: size)
            let elapsed = Float(now - start)
            uniforms.paramsA.x = reducedMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 43_200)
            uniforms.paramsB.x = dynamics.flowPhase
            uniforms.paramsB.y = dynamics.breathPhase
            uniforms.viewport.z = Float(view.drawableSize.width / max(view.bounds.width, 1))
            contactCurrent = reducedMotion ? contactTarget : contactCurrent + (contactTarget - contactCurrent) * 0.15
            uniforms.bind(encoder)
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.setRenderPipelineState(particlePipeline)
            var touch = contactCurrent
            encoder.setVertexBytes(&touch, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 24_000)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            needsRender = false
        }
    }
}

/// CPU-side mirror of the Metal uniform block (float4 aligned).
struct KairoRingUniformsStorage {
    var viewport = SIMD4<Float>(1, 1, 0.5, 0.5)
    var mood = SIMD4<Float>(0.372, 0.702, 1.0, 0)
    var accent = SIMD4<Float>(0.902, 0.973, 1.0, 0)
    var core = SIMD4<Float>(1, 1, 1, 0)
    var paramsA = SIMD4<Float>(0, 0.35, 0, 0.9)
    var paramsB = SIMD4<Float>(0.34, 0.05, 1, 0)
    var paramsC = SIMD4<Float>(0, 0, 0, 0)
    // Metal arrays are inline. A Swift Array is a heap reference and cannot
    // be uploaded as part of this uniform struct.
    private var emitterStorage: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    ) = (.zero, .zero, .zero, .zero, .zero, .zero,
         .zero, .zero, .zero, .zero, .zero, .zero)

    mutating func apply(_ state: RingRenderState, viewport: CGSize) {
        self.viewport = SIMD4<Float>(Float(viewport.width), Float(viewport.height), 0, 0)
        mood = SIMD4<Float>(state.moodPrimary, 0)
        accent = SIMD4<Float>(state.moodAccent, 0)
        core = SIMD4<Float>(state.coreColor, 0)
        paramsA.y = state.breath
        paramsA.z = state.energy
        paramsA.w = state.intensity
        // Integrated flow/breath phases are supplied by the renderer.
        paramsB.x = 0
        paramsB.y = 0
        paramsB.z = state.fade
        paramsB.w = state.sleeping ? 1 : 0
        paramsC = SIMD4<Float>(Float(state.activity.rawValue), state.activityLevel,
                               Float(state.motion.rawValue), state.arousal)
        let levels = state.emitterLevels.count == 12 ? state.emitterLevels :
            RingMirror.resample(state.emitterLevels.map(Double.init), to: 12).map(Float.init)
        withUnsafeMutableBytes(of: &emitterStorage) { bytes in
            for index in 0..<12 {
                let emitter = SIMD4<Float>(levels[safe: index] ?? 0, Float(index) * 0.53, 0, 0)
                bytes.storeBytes(of: emitter, toByteOffset: index * 16, as: SIMD4<Float>.self)
            }
        }
    }

    mutating func bind(_ encoder: MTLRenderCommandEncoder) {
        var storage = self
        encoder.setVertexBytes(&storage, length: MemoryLayout<KairoRingUniformsStorage>.stride, index: 0)
        encoder.setFragmentBytes(&storage, length: MemoryLayout<KairoRingUniformsStorage>.stride, index: 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
