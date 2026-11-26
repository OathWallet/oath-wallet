#if os(iOS)
import CoreHaptics
import Combine
import UIKit
import OathDiagnostics

@MainActor final class BalanceChartHaptics: ObservableObject {
    private var engine: CHHapticEngine?
    private var policy = BalanceChartHapticPolicy()
    private var running = false
    private var stopping = false
    private var failed = false
    private var operationID = UUID()

    func prepare() {
        // Unsupported hardware is an expected capability, not an app failure.
        guard engine == nil, !failed, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.running = false
                    if reason == .systemError {
                        self?.report(NSError(domain: "OathBalanceChart.HapticEngineStopped", code: reason.rawValue), operation: "engine_stopped")
                    }
                    // Interruption, suspension, idle and explicit stops are normal lifecycle events.
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    // Players are transient. Restart lazily on the next user tick.
                    self?.running = false
                }
            }
            self.engine = engine
        } catch {
            OathDiagnostics.$operationID.withValue(operationID) {
                OathDiagnostics.record(error, component: "balance_chart", operation: "create_engine")
            }
            failed = true
        }
    }

    func tick(_ tick: BalanceChartTick, enabled: Bool) {
        guard enabled, UIApplication.shared.applicationState == .active, !failed, !stopping,
              let parameters = policy.sample(index: tick.index, direction: tick.direction,
                  displacement: tick.displacement, time: ProcessInfo.processInfo.systemUptime) else { return }
        prepare()
        guard let engine else { return }
        do {
            if !running { try engine.start(); running = true }
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: parameters.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: parameters.sharpness)
            ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            OathDiagnostics.$operationID.withValue(operationID) {
                OathDiagnostics.record(error, component: "balance_chart", operation: "play_tick")
            }
            failed = true
        }
    }

    func end() {
        policy.reset(); failed = false
        let id = operationID
        operationID = UUID()
        guard running, let engine else { return }
        running = false; stopping = true
        engine.stop { [weak self] error in
            Task { @MainActor [weak self] in
                self?.stopping = false
                if let error {
                    OathDiagnostics.$operationID.withValue(id) {
                        OathDiagnostics.record(error, component: "balance_chart", operation: "stop_haptics")
                    }
                }
            }
        }
    }

    private func report(_ error: Error, operation: String) {
        OathDiagnostics.$operationID.withValue(operationID) {
            OathDiagnostics.record(error, component: "balance_chart", operation: operation)
        }
    }
}
#endif
