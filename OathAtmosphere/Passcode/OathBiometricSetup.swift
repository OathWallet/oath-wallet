import Foundation
import LocalAuthentication

enum OathBiometricKind: String, Equatable, Sendable {
    case faceID, touchID

    var name: String { self == .faceID ? "Face ID" : "Touch ID" }

    static func availableForUnlock() -> Self? {
        #if os(iOS)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

enum OathBiometricSetupError: Error, Equatable, Sendable {
    case cancelled, interrupted, lockedOut, notRecognized, unavailable, storage
}

enum OathBiometricSetupResult: Equatable, Sendable {
    case unavailable
    case enabled(OathBiometricKind)
    case failed(kind: OathBiometricKind?, reason: OathBiometricSetupError)
}

protocol OathBiometricsEnabling: Sendable {
    /// Attempts enrollment automatically when biometrics are available. Success
    /// means both authentication and protected credential persistence succeeded.
    func enableIfAvailable() async -> OathBiometricSetupResult
}
