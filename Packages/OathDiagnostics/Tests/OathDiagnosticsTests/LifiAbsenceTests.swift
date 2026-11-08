import Foundation
import XCTest
@testable import OathDiagnostics

final class LifiAbsenceTests: XCTestCase {
    func testOnlyExactOptionalTokenAbsenceIsExcluded() throws {
        let token = "0x0000000000000000000000000000000000000001"
        let request = URLRequest(url: URL(string: "https://li.quest/v1/token?chain=1&token=" + token)!)
        let row: [String: Any] = ["message": "Could not find token '\(token)' on chain '1' (\(token))", "code": 1003]
        let bytes = try JSONSerialization.data(withJSONObject: row)
        XCTAssertTrue(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: request))
        for status in [200, 400, 401, 403, 429, 500, 503] {
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: status, request: request))
        }
        for url in ["https://other.example/v1/token?chain=1&token=" + token,
                    "https://li.quest/v1/tokens?chain=1&token=" + token,
                    "https://li.quest/v1/token?chain=2&token=" + token,
                    "https://li.quest/v1/token?chain=1&token=OTHER",
                    "https://li.quest/v1/token?chain=1&token=" + token + "&apiKey=fixture"] {
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: URLRequest(url: URL(string: url)!)))
        }
        for body in [Data("proxy 404".utf8), try JSONSerialization.data(withJSONObject: ["code": 1003]),
                     try JSONSerialization.data(withJSONObject: ["code": 1001, "message": row["message"]!]),
                     try JSONSerialization.data(withJSONObject: ["code": 1003, "message": "authentication failed"])] {
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(body, status: 404, request: request))
        }
        var post = request; post.httpMethod = "POST"
        XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: post))
        var body = request; body.httpBody = Data("fixture".utf8)
        XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: body))
    }
}
