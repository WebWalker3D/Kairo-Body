import MetalKit
import XCTest
@testable import KairoBody

final class ParticleRenderTests: XCTestCase {
    // Exercise the shipping shader on a real Metal target. A successful build
    // alone cannot catch a blank, clipped, or non-responsive particle pass.
    func testParticleFieldRendersAndRespondsToTimeTouchAndSleep() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let library = try XCTUnwrap(device.makeDefaultLibrary())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "kairoParticleVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "kairoParticleFragment"))
        let colour = descriptor.colorAttachments[0]!
        colour.pixelFormat = .rgba8Unorm
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .one
        colour.destinationRGBBlendFactor = .one
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .one
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let size = 640
        func render(time: Float, touch: SIMD4<Float> = .zero, sleeping: Bool = false) throws -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: size, height: size, mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var state = RingRenderState()
            state.sleeping = sleeping
            var uniforms = KairoRingUniformsStorage()
            uniforms.apply(state, viewport: CGSize(width: size, height: size))
            uniforms.paramsA.x = time
            uniforms.viewport.z = 1
            uniforms.bind(encoder)
            var contact = touch
            encoder.setVertexBytes(&contact, length: 16, index: 1)
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 24_000)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "")
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                                 from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            return bytes
        }
        let still = try render(time: 0)
        let moved = try render(time: 4)
        let touched = try render(time: 0, touch: SIMD4<Float>(0.5, 0, 1, 0))
        let sleeping = try render(time: 0, sleeping: true)
        let lit = stride(from: 0, to: still.count, by: 4).filter { still[$0+2] > 30 }.count
        XCTAssertGreaterThan(lit, 8_000, "Particle body must occupy a substantial visible field")
        XCTAssertLessThan(lit, size * size / 2, "Keep negative space around the body")
        XCTAssertNotEqual(still, moved, "Time must move the particle geometry")
        XCTAssertNotEqual(still, touched, "Touch must deform the field")
        XCTAssertEqual(still, try render(time: 0), "Frozen time must remain stable for Reduce Motion")
        let light: ([UInt8]) -> Int = { bytes in
            stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1+2]) }
        }
        XCTAssertLessThan(light(sleeping), light(still) / 3)
    }
}
