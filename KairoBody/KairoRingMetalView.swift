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
    var energy: Float = 0.0
    var intensity: Float = 0.9
    var sleeping = false
    var fade: Float = 1
}

struct KairoRingMetalView: UIViewRepresentable {
    let state: RingRenderState
    var framesPerSecond: Int = 30

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = framesPerSecond
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.apply(state, size: view.bounds.size)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var uniforms = KairoRingUniformsStorage()
        private var start = CFAbsoluteTimeGetCurrent()
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
            view.delegate = self
        }

        func apply(_ state: RingRenderState, size: CGSize) {
            uniforms.apply(state, viewport: size)
            self.size = size
            needsRender = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { self.size = size }

        func draw(in view: MTKView) {
            guard let pipeline, let queue, let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            uniforms.paramsA.x = Float(CFAbsoluteTimeGetCurrent() - start)
            uniforms.bind(encoder)
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
    var emitters: [SIMD4<Float>] = Array(repeating: .zero, count: 12)

    mutating func apply(_ state: RingRenderState, viewport: CGSize) {
        self.viewport = SIMD4<Float>(Float(viewport.width), Float(viewport.height), 0, 0)
        mood = SIMD4<Float>(state.moodPrimary, 0)
        accent = SIMD4<Float>(state.moodAccent, 0)
        core = SIMD4<Float>(state.coreColor, 0)
        paramsA.y = state.breath
        paramsA.z = state.energy
        paramsA.w = state.intensity
        // Ring radius and emitter width in the shader's normalized space.
        paramsB.x = 0.34
        paramsB.y = 0.055
        paramsB.z = state.fade
        paramsB.w = state.sleeping ? 1 : 0
        let levels = state.emitterLevels.count == 12 ? state.emitterLevels :
            RingMirror.resample(state.emitterLevels.map(Double.init), to: 12).map(Float.init)
        for index in 0..<12 {
            emitters[index] = SIMD4<Float>(levels[safe: index] ?? 0, Float(index) * 0.53, 0, 0)
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
