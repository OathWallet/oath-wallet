import Foundation

public enum PushRetryPolicy {
    public static func isPermanent(_ error: Error) -> Bool {
        guard let http = error as? HTTPError, case .badStatusCode(let status) = http else { return false }
        return (400...499).contains(status) && status != 408 && status != 429
    }
}

/// Only a 401 with a fresh same-origin server clock can cause one re-sign.
/// Invalid signatures/audiences still fail; there is no relaxed server policy.
func withPushAuthentication<T>(client: HTTPClient, authenticator: PushAuthenticating,
                               request: (String) async throws -> T) async throws -> T {
    let initialDate = await client.serverDate()
    do { return try await request(authenticator.createAuthToken(at: initialDate)) }
    catch HTTPError.badStatusCode(401) {
        guard initialDate == nil, let date = await client.serverDate(),
              abs(date.timeIntervalSinceNow) <= 86_400 else { throw HTTPError.badStatusCode(401) }
        try Task.checkCancellation()
        return try await request(authenticator.createAuthToken(at: date))
    }
}
