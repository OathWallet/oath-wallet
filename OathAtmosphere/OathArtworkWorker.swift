import OathDiagnostics
import MetalKit

/// Serializes only the final commit with lifecycle revocation. Drawable acquisition
/// and encoding stay outside the lock, so suspension never waits for a drawable.
final class OathArtworkSubmissionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var last: MTLCommandBuffer?

    func commit(_ command: MTLCommandBuffer, gate: OathArtworkFrameGate,
                ticket: OathArtworkFrameGate.Ticket) -> Bool {
        lock.withLock {
            guard gate.isCurrent(ticket) else { return false }
            command.commit()
            last = command
            return true
        }
    }

    func suspend(_ gate: OathArtworkFrameGate) {
        gate.setEnabled(false)
        let submitted = lock.withLock { let command = last; last = nil; return command }
        // iOS requires committed work to be scheduled before backgrounding.
        // All commands for this surface share a queue. Waiting for the last
        // one covers its predecessors without waiting for GPU completion.
        submitted?.waitUntilScheduled()
    }

    func completed(_ command: MTLCommandBuffer) {
        lock.withLock { if last === command { last = nil } }
    }
}

/// Drawable waits are isolated per surface: a covered Home canvas cannot stall
/// the visible Customize/Welcome canvas. Encoding shares one queue to preserve
/// logo preparation ordering, with one outstanding frame per surface.
final class OathArtworkWorker: Sendable {
    enum Result: Sendable { case presented, unavailable, failed(String) }
    static let queue = DispatchQueue(label: "org.oathwallet.artwork", qos: .userInteractive)
    private let drawableQueue = DispatchQueue(label: "org.oathwallet.artwork.drawable", qos: .userInteractive)
    let gate = OathArtworkFrameGate()
    private let submissions = OathArtworkSubmissionFence()

    func suspend() { submissions.suspend(gate) }

    // CAMetalLayer is designed for background drawable acquisition. UIKit alone
    // changes its geometry/device; this reference never exposes the UIView.
    private struct Target: @unchecked Sendable { let layer: CAMetalLayer }
    private struct Drawable: @unchecked Sendable { let value: CAMetalDrawable }

    @discardableResult
    func submit(layer: CAMetalLayer, resources: OathArtworkResources,
                uniforms: AtmosphereUniforms, colors: OathSilkColors,
                completion: @escaping @MainActor @Sendable (Result) -> Void) -> Bool {
        guard let ticket = gate.begin() else { return false }
        let target = Target(layer: layer)
        let finish: @Sendable (Result) -> Void = { [gate] result in
            Task { @MainActor in
                // Keep the in-flight slot until the UI actor consumes the
                // outcome. Neither stale failures nor a callback backlog can
                // overtake a later frame after backgrounding/reattachment.
                let current = gate.isCurrent(ticket)
                gate.finish(ticket)
                guard current else { return }
                completion(result)
            }
        }
        drawableQueue.async { [gate, submissions] in
            autoreleasepool {
                guard gate.isCurrent(ticket), let drawable = target.layer.nextDrawable(), gate.isCurrent(ticket) else {
                    finish(.unavailable)
                    return
                }
                let retained = Drawable(value: drawable)
                Self.queue.async {
                    autoreleasepool {
                        guard gate.isCurrent(ticket) else { finish(.unavailable); return }
                        guard let command = resources.queue.makeCommandBuffer() else {
                            finish(.failed("Metal command buffer unavailable")); return
                        }
                        do { try resources.encodeLogoIfNeeded(into: command) }
                        catch { OathDiagnostics.record(error); finish(.failed(error.localizedDescription)); return }
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = retained.value.texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                            finish(.failed("Metal encoder unavailable")); return
                        }
                        var uniforms = uniforms
                        var colors = colors
                        encoder.setRenderPipelineState(resources.pipeline)
                        encoder.setFragmentTexture(resources.logoNormals, index: 0)
                        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
                        encoder.setFragmentBytes(&colors, length: MemoryLayout<OathSilkColors>.stride, index: 1)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        encoder.endEncoding()
                        guard gate.isCurrent(ticket) else { finish(.unavailable); return }
                        command.addCompletedHandler { command in
                            submissions.completed(command)
                            finish(command.status == .completed ? .presented
                                   : .failed(command.error?.localizedDescription ?? "Metal command failed"))
                        }
                        command.present(retained.value)
                        guard submissions.commit(command, gate: gate, ticket: ticket) else { finish(.unavailable); return }
                        resources.didSubmit()
                    }
                }
            }
        }
        return true
    }
}
