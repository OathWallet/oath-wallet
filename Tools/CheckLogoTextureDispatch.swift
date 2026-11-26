import Foundation
import MetalKit

/// Run with the repository path on a Mac or via simctl spawn with Metal validation enabled.
@main struct CheckLogoTextureDispatch {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required")
        }
        let shader = try String(contentsOf: root.appendingPathComponent("Shaders/OathSilk.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: shader, options: nil)
        let logo = try OathLogoTexture.prepare(url: root.appendingPathComponent("OathApp/Resources/OathGlassNormals.png"),
                                               device: device, library: library)
        let firstFrame = queue.makeCommandBuffer()!
        try logo.encode(into: firstFrame)
        try finish(firstFrame)
        print("Prepared the bundled \(logo.texture.width) × \(logo.texture.height) logo on \(device.name).")

        // Neither dimension is a multiple of 16. Missing either partial group
        // loses the last pixel; skipping mip generation loses the final level.
        let width = 19, height = 17
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let source = device.makeTexture(descriptor: descriptor)!
        let magenta: [UInt8] = [255, 0, 255, 128]
        let pixels = Array(repeating: magenta, count: width * height).flatMap { $0 }
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        outputDescriptor.storageMode = .private
        let output = device.makeTexture(descriptor: outputDescriptor)!
        let command = queue.makeCommandBuffer()!
        try OathLogoTexture.Preparation(source: source, texture: output, pipeline: logo.pipeline).encode(into: command)

        let readback = device.makeBuffer(length: 512, options: .storageModeShared)!
        let blit = command.makeBlitCommandEncoder()!
        for (index, level) in [0, output.mipmapLevelCount - 1].enumerated() {
            let corner = MTLOrigin(x: max(1, width >> level) - 1, y: max(1, height >> level) - 1, z: 0)
            blit.copy(from: output, sourceSlice: 0, sourceLevel: level, sourceOrigin: corner,
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback,
                      destinationOffset: index * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        }
        blit.endEncoding()
        try finish(command)
        for offset in [0, 256] {
            let pixel = readback.contents().advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let rgba = Array(UnsafeBufferPointer(start: pixel, count: 4))
            precondition(rgba == [128, 0, 128, 128], "Unexpected RGBA \(rgba) at buffer offset \(offset)")
        }
        print("Verified the last pixel of a 19 × 17 texture and its 1 × 1 mip level.")
    }

    private static func finish(_ command: MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        precondition(command.status == .completed)
    }
}
