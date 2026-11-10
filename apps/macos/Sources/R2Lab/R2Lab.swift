import Foundation
import CryptoKit
import PagingStore

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func mac(_ key: Data, _ text: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
}
enum LabError: Error { case config, response(Int), integrity }

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct R2Client {
    let endpoint: URL
    let bucket: String
    let access: String
    let secret: String
    let session: URLSession
    init(env: [String: String] = ProcessInfo.processInfo.environment, configuration: URLSessionConfiguration? = nil) throws {
        guard let urlText = env["R2_ENDPOINT"], let url = URL(string: urlText),
              url.scheme == "https", let host = url.host, host.hasSuffix(".r2.cloudflarestorage.com"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil, url.path.isEmpty || url.path == "/",
              let bucket = env["R2_BUCKET"], bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
              let access = env["R2_ACCESS_KEY_ID"], !access.isEmpty,
              let secret = env["R2_SECRET_ACCESS_KEY"], !secret.isEmpty else { throw LabError.config }
        self.endpoint = url; self.bucket = bucket; self.access = access; self.secret = secret
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func signedRequest(_ method: String, key: String, body: Data = Data(), now: Date = Date()) throws -> URLRequest {
        guard ["PUT", "GET", "DELETE"].contains(method),
              key.range(of: "^cloudswap-lab/[a-z0-9-]+/probe$", options: .regularExpression) != nil,
              body.count <= 32768, method == "PUT" || body.isEmpty else { throw LabError.config }
        let uri = "/\(bucket)/\(key)"
        let url = endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let date = formatter.string(from: now)
        let day = String(date.prefix(8))
        let scope = "\(day)/auto/s3/aws4_request"
        let payloadHash = sha(body)
        let headers = "host:\(endpoint.host!)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(date)\n"
        let signed = "host;x-amz-content-sha256;x-amz-date"
        let canonical = "\(method)\n\(uri)\n\n\(headers)\n\(signed)\n\(payloadHash)"
        let signingKey = mac(mac(mac(mac(Data(("AWS4" + secret).utf8), day), "auto"), "s3"), "aws4_request")
        let signature = mac(signingKey, "AWS4-HMAC-SHA256\n\(date)\n\(scope)\n\(sha(Data(canonical.utf8)))").map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "PUT" { request.httpBody = body }
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(date, forHTTPHeaderField: "x-amz-date")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(access)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
    func request(_ method: String, key: String, body: Data = Data()) async throws -> Data {
        let request = try signedRequest(method, key: key, body: body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LabError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

@main struct R2Lab {
    static func main() async {
        if CommandLine.arguments.contains("--pager-live") { await pagerLive(); return }
        if CommandLine.arguments.contains("--self-test") {
            do {
                let key = SymmetricKey(size: .bits256)
                let bytes = Data(repeating: 0x45, count: 16384)
                let sealed = try AES.GCM.seal(bytes, using: key, authenticating: Data("test-object".utf8))
                let plain = try AES.GCM.open(sealed, using: key, authenticating: Data("test-object".utf8))
                guard plain == bytes else { throw LabError.integrity }
                do {
                    _ = try AES.GCM.open(sealed, using: key, authenticating: Data("wrong-object".utf8))
                    throw LabError.integrity
                } catch CryptoKitError.authenticationFailure { }
                guard sha(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" else { throw LabError.integrity }
                print("PASS: AES-GCM round trip, object identity authentication, SHA-256 known answer. No R2 requests made.")
            } catch { print("FAIL: local cryptography self-test"); exit(1) }
            return
        }
        guard CommandLine.arguments.contains("--live") else {
            print("Use --self-test or --live. Live mode uploads 16 KiB of encrypted synthetic data to the configured R2 bucket, verifies it, and deletes that object.")
            return
        }
        var cleanup: (R2Client, String)?
        do {
            let client = try R2Client()
            let object = "cloudswap-lab/\(UUID().uuidString.lowercased())/probe"
            cleanup = (client, object) // Also clean up ambiguous PUTs.
            let key = SymmetricKey(size: .bits256)
            let plain = Data((0..<16384).map { _ in UInt8.random(in: 0...255) })
            let encrypted = try AES.GCM.seal(plain, using: key, authenticating: Data(object.utf8)).combined!
            let start = Date()
            _ = try await client.request("PUT", key: object, body: encrypted)
            let fetched = try await client.request("GET", key: object)
            let recovered = try AES.GCM.open(AES.GCM.SealedBox(combined: fetched), using: key, authenticating: Data(object.utf8))
            guard sha(plain) == sha(recovered) else { throw LabError.integrity }
            print("Verified 16384 synthetic bytes. PUT + GET: \(Int(Date().timeIntervalSince(start)*1000)) ms. This is not system swap.")
            _ = try await client.request("DELETE", key: object)
            cleanup = nil
        } catch {
            // Do not log errors containing URLs, headers or credentials.
            print("R2 probe failed: configuration, network, HTTP response or integrity error. No system swap was changed.")
            if let (client, object) = cleanup {
                do { _ = try await client.request("DELETE", key: object) }
                catch { print("Cleanup unconfirmed. Remove this synthetic object when connectivity returns: \(object)") }
            }
            exit(1)
        }
    }
}

extension R2Client: ObjectBackend {
    func put(key: String, data: Data) async throws { _ = try await request("PUT", key: key, body: data) }
    func get(key: String) async throws -> Data {
        try await readWithRetry(key: key, budget: .milliseconds(2500))
    }

    func readWithRetry(key: String, budget: Duration) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        while clock.now < deadline {
            do {
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await request("GET", key: key) }
                    group.addTask {
                        try await clock.sleep(until: deadline, tolerance: .zero)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    guard let response = try await group.next() else { throw CancellationError() }
                    return response
                }
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                     .dnsLookupFailed, .timedOut:
                    guard clock.now < deadline else { throw error }
                    let nextAttempt = clock.now.advanced(by: .milliseconds(50))
                    try await clock.sleep(until: min(nextAttempt, deadline), tolerance: .zero)
                default:
                    throw error
                }
            }
        }
        throw URLError(.timedOut)
    }
}


actor TrackedLabBackend: ObjectBackend {
    let client: R2Client
    var keys: [String] = []
    init(_ client: R2Client) { self.client = client }
    func put(key: String, data: Data) async throws {
        keys.append(key)
        try await client.put(key: key, data: data)
    }
    func get(key: String) async throws -> Data { try await client.get(key: key) }
    func cleanup() async -> Bool {
        var success = true
        for key in keys {
            do { _ = try await client.request("DELETE", key: key) }
            catch { print("Cleanup unconfirmed for synthetic object: \(key)"); success = false }
        }
        return success
    }
}
extension R2Lab {
    static func pagerLive() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var backend: TrackedLabBackend?
        var passed = false
        do {
            let b = TrackedLabBackend(try R2Client()); backend = b
            let key = SymmetricKey(size: .bits256)
            var pager: RemotePager? = try RemotePager(directory: root, key: key, backend: b, create: true)
            let data = Data((0..<PagingStore.blockSize).map { _ in UInt8.random(in: 0...255) })
            try await pager!.write(block: 0, data: data)
            pager = nil
            let reopened = try RemotePager(directory: root, key: key, backend: b)
            let restored = try await reopened.read(block: 0)
            guard restored == data else { throw LabError.integrity }
            print("PASS: encrypted remote page recovered after pager reopen. Synthetic data only; no system swap.")
            passed = true
        } catch { print("Remote paging lab failed. No system swap was changed.") }
        if let b = backend { if !(await b.cleanup()) { passed = false } }
        try? FileManager.default.removeItem(at: root)
        if !passed { exit(1) }
    }
}
