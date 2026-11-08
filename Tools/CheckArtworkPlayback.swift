import Foundation

/// Production playback and energy logic, run on the Mac without an iOS runtime.
@main struct CheckArtworkPlayback {
    static func main() {
        var playback = OathArtworkPlayback()
        precondition(playback.needsFrame && !playback.hasPresentedFrame)
        precondition(!playback.shouldTick(canDraw: false, animating: true))
        precondition(playback.shouldTick(canDraw: true, animating: false))

        let first = playback.revision
        playback.requestFrame() // New color arrives while the first frame waits.
        playback.didPresent(revision: first)
        precondition(playback.needsFrame, "An older completion must not consume the current color update")
        playback.didPresent(revision: playback.revision)
        precondition(!playback.needsFrame && playback.hasPresentedFrame)
        precondition(!playback.shouldTick(canDraw: true, animating: false))
        precondition(playback.shouldTick(canDraw: true, animating: true))

        _ = playback.advance(at: 10, animating: true)
        for tick in 1...240 {
            playback.requestFrame() // Continuous palette/layout edits.
            _ = playback.advance(at: 10 + Double(tick) / 60, animating: true)
            playback.didPresent(revision: playback.revision)
        }
        precondition(abs(playback.elapsed - 4) < 0.0001, "Color changes must not restart animation time")
        _ = playback.advance(at: 16, animating: true)
        precondition(abs(playback.elapsed - 6) < 0.0001, "Skipped frames must not slow the animation clock")
        playback.pause()
        _ = playback.advance(at: 100, animating: true)
        precondition(playback.elapsed == 6, "Time spent backgrounded must not jump the animation")
        _ = playback.advance(at: 101, animating: true)
        precondition(playback.elapsed == 7)

        playback.pause()
        _ = playback.advance(at: 105, animating: false) // Reduce Motion/covered.
        playback.requestFrame()
        _ = playback.advance(at: 110, animating: false)
        precondition(playback.elapsed == 7 && playback.needsFrame)
        playback.didPresent(revision: playback.revision)
        playback.didPresent(revision: first) // A delayed earlier completion.
        precondition(!playback.needsFrame, "Out-of-order callbacks cannot dirty completed colors")

        for expected in [0.25, 1.0, 3.0] {
            precondition(playback.renderingFailed() == expected)
        }
        precondition(playback.renderingFailed() == nil && playback.recoveryExhausted)
        precondition(!playback.shouldTick(canDraw: true, animating: true), "Permanent failure must not spin")
        playback.resume() // Return from background, reattach, or thermal recovery.
        precondition(!playback.recoveryExhausted && playback.needsFrame && playback.elapsed == 7)
        precondition(playback.shouldTick(canDraw: true, animating: true))
        precondition(playback.renderingFailed() == 0.25)
        playback.didPresent(revision: playback.revision)
        precondition(playback.failures == 0)

        for state: ProcessInfo.ThermalState in [.nominal, .fair, .serious] {
            let policy = OathArtworkEnergyPolicy(thermalState: state, lowPower: false)
            precondition(playback.shouldTick(canDraw: policy.rendersFrames, animating: policy.animates))
        }
        let critical = OathArtworkEnergyPolicy(thermalState: .critical, lowPower: false)
        precondition(!playback.shouldTick(canDraw: critical.rendersFrames, animating: critical.animates))

        // A mature canvas must accelerate from its existing phase, not multiply
        // that phase (or rewind it when the 2.5-second presentation ends).
        for framesPerSecond in [30.0, 60.0, 120.0] {
            var refreshed = OathArtworkPlayback()
            _ = refreshed.advance(at: 0, animating: true)
            _ = refreshed.advance(at: 120, animating: true)
            let step = 1 / framesPerSecond
            var previous = refreshed.elapsed
            for frame in 1...Int(2.5 * framesPerSecond) {
                let realDelta = refreshed.advance(at: 120 + Double(frame) * step, animating: true, rate: 3)
                precondition(abs(realDelta - step) < 0.0001, "Speed must not change the real frame interval")
                precondition(abs(refreshed.elapsed - previous - 3 * step) < 0.0001,
                             "Refresh advances only the next interval at 3x; it never seeks")
                previous = refreshed.elapsed
            }
            precondition(abs(refreshed.elapsed - 127.5) < 0.0001, "Refresh speed is independent of frame rate")
            // Sample a decreasing presentation rate. SwiftUI supplies the eased
            // rates; the production clock must remain continuous at each one.
            for (index, rate) in [2.8, 2.1, 1.4, 1.0].enumerated() {
                _ = refreshed.advance(at: 122.5 + Double(index + 1) * step, animating: true, rate: rate)
                precondition(abs(refreshed.elapsed - previous - rate * step) < 0.0001,
                             "Deceleration must never rewind the artwork")
                previous = refreshed.elapsed
            }
            _ = refreshed.advance(at: 124.5 + 4 * step, animating: true)
            precondition(abs(refreshed.elapsed - previous - 2) < 0.0001, "Normal speed is restored")
            previous = refreshed.elapsed
            refreshed.pause()
            _ = refreshed.advance(at: 200, animating: true, rate: 3)
            precondition(refreshed.elapsed == previous, "Resuming a refresh must not include covered time")
            _ = refreshed.advance(at: 201, animating: false, rate: 3)
            _ = refreshed.advance(at: 250, animating: false, rate: 1)
            precondition(refreshed.elapsed == previous, "Reduce Motion remains still, including speed changes")
        }
        print("PASS: palette updates, refresh acceleration/deceleration at 30/60/120Hz, continuous phase, normal-speed restoration, pause/resume, Reduce Motion, bounded retries and thermal recovery")
    }
}
