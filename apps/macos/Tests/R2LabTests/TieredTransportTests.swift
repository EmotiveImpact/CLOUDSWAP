import XCTest
import Foundation
import PagingStore
@testable import R2Lab

private final class ObjectServiceStub: URLProtocol {
    static let lock = NSLock()
    static var objects: [String: Data] = [:]
    static var methods: [String] = []
    static var allSigned = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let method = request.httpMethod!
        let path = request.url!.path
        Self.lock.lock()
        Self.methods.append(method)
        Self.allSigned = Self.allSigned && request.value(forHTTPHeaderField: "Authorization") != nil
        var status = 200
        var response = Data()
        switch method {
        case "PUT": Self.objects[path] = body
        case "GET":
            if let bytes = Self.objects[path] { response = bytes } else { status = 404 }
        case "DELETE": Self.objects.removeValue(forKey: path)
        default: status = 405
        }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); defer { lock.unlock() }; objects = [:]; methods = []; allSigned = true }
    static func result() -> ([String], Int, Bool) { lock.lock(); defer { lock.unlock() }; return (methods, objects.count, allSigned) }
}

final class TieredTransportTests: XCTestCase {
    func testR2AdapterRunsWholeTrialAndCleansOnlyItsObjects() async throws {
        ObjectServiceStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ObjectServiceStub.self]
        let client = try R2Client(env: ["R2_ENDPOINT": "https://example.r2.cloudflarestorage.com", "R2_BUCKET": "test-bucket",
                                        "R2_ACCESS_KEY_ID": "synthetic", "R2_SECRET_ACCESS_KEY": "synthetic"], configuration: config)
        defer { client.session.invalidateAndCancel() }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let report = await TieredTrial.run(parent: parent, backend: client, blocks: 2)
        XCTAssertTrue(report.passed, "Failed at \(report.failedStage ?? "cleanup")")
        let (methods, remaining, signed) = ObjectServiceStub.result()
        XCTAssertEqual(methods, ["PUT", "PUT", "GET", "GET", "DELETE", "DELETE"])
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(signed)
        XCTAssertEqual(report.blockedOperations, 1)
    }
}
