import XCTest
import Foundation
@testable import R2Lab

final class Stub: URLProtocol {
    static var status = 200
    static var failure: URLError.Code?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let code = Self.failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("synthetic".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class TransportTests: XCTestCase {
    let env = ["R2_ENDPOINT":"https://example.r2.cloudflarestorage.com", "R2_BUCKET":"test-bucket", "R2_ACCESS_KEY_ID":"test", "R2_SECRET_ACCESS_KEY":"synthetic-secret"]
    let key = "cloudswap-lab/test-session/probe"
    func client() throws -> R2Client {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        Stub.status = 200; Stub.failure = nil
        return try R2Client(env: env, configuration: config)
    }
    func testEndpointValidation() {
        for bad in ["http://example.r2.cloudflarestorage.com", "https://evil.example", "https://example.r2.cloudflarestorage.com/path", "https://user:password@example.r2.cloudflarestorage.com"] {
            var values = env; values["R2_ENDPOINT"] = bad
            XCTAssertThrowsError(try R2Client(env: values))
        }
    }
    func testBoundedRequests() throws {
        let c = try client(); defer { c.session.invalidateAndCancel() }
        XCTAssertThrowsError(try c.signedRequest("PUT", key: key, body: Data(count: 32769)))
        XCTAssertThrowsError(try c.signedRequest("GET", key: "../secret"))
        XCTAssertThrowsError(try c.signedRequest("POST", key: key))
        XCTAssertThrowsError(try c.signedRequest("GET", key: key, body: Data([1])))
    }
    func testHMACIndependentKnownAnswer() {
        // RFC 4231 case 1.
        let result = mac(Data(repeating: 0x0b, count: 20), "Hi There").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(result, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }
    func testSignedRequestChangesWithPayload() throws {
        let c = try client(); defer { c.session.invalidateAndCancel() }
        let date = Date(timeIntervalSince1970: 0)
        let a = try c.signedRequest("PUT", key: key, body: Data([1]), now: date)
        let b = try c.signedRequest("PUT", key: key, body: Data([2]), now: date)
        XCTAssertEqual(a.value(forHTTPHeaderField: "x-amz-date"), "19700101T000000Z")
        XCTAssertEqual(a.url?.path, "/test-bucket/" + key)
        XCTAssertNotEqual(a.value(forHTTPHeaderField: "Authorization"), b.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(a.value(forHTTPHeaderField: "Authorization")!.contains("synthetic-secret"))
    }
    func testOfflineAndReconnect() async throws {
        let c = try client(); defer { c.session.invalidateAndCancel() }
        Stub.failure = .notConnectedToInternet
        do { _ = try await c.request("GET", key: key); XCTFail("Offline request succeeded") } catch { }
        Stub.failure = nil
        let result = try await c.request("GET", key: key)
        XCTAssertEqual(result, Data("synthetic".utf8))
    }
    func testHTTPFailuresAreNotAcknowledged() async throws {
        let c = try client(); defer { c.session.invalidateAndCancel() }
        for status in [301, 403, 404, 429, 500, 503] {
            Stub.status = status
            do { _ = try await c.request("PUT", key: key, body: Data([1])); XCTFail("Accepted HTTP failure") }
            catch LabError.response(let actual) { XCTAssertEqual(actual, status) }
        }
    }
    func testTimeoutPropagates() async throws {
        let c = try client(); defer { c.session.invalidateAndCancel() }
        Stub.failure = .timedOut
        do { _ = try await c.request("PUT", key: key, body: Data([1])); XCTFail("Acknowledged timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }
}
