import XCTest
import CryptoKit
@testable import PagingStore

actor MemoryObjects: ObjectBackend {
    var objects: [String: Data] = [:]
    var offline = false
    var loseAck = false
    func fault(offline: Bool = false, loseAck: Bool = false) { self.offline = offline; self.loseAck = loseAck }
    func put(key: String, data: Data) throws {
        if offline { throw URLError(.notConnectedToInternet) }
        objects[key] = data
        if loseAck { throw URLError(.timedOut) }
    }
    func get(key: String) throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let data = objects[key] else { throw PagingError.missing }
        return data
    }
    func corrupt() { for key in objects.keys { objects[key] = Data(repeating: 0, count: 100) } }
}
final class RemotePagerTests: XCTestCase {
    var root: URL!
    let key = SymmetricKey(size: .bits256)
    let payload = Data(repeating: 0x72, count: PagingStore.blockSize)
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func testRemoteRoundTripAndSmallLocalIndex() async throws {
        let backend = MemoryObjects()
        let p = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await p.write(block: 0, data: payload)
        let restored = try await p.read(block: 0)
        XCTAssertEqual(restored, payload)
        let bytes = try Data(contentsOf: root.appendingPathComponent("remote-index.enc"))
        XCTAssertLessThan(bytes.count, 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testRemoteReopen() async throws {
        let backend = MemoryObjects()
        var p: RemotePager? = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await p!.write(block: 3, data: payload); p = nil
        let reopened = try RemotePager(directory: root, key: key, backend: backend)
        let restored = try await reopened.read(block: 3)
        XCTAssertEqual(restored, payload)
    }
    func testOfflineReadThenRecovery() async throws {
        let backend = MemoryObjects()
        let p = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await p.write(block: 0, data: payload)
        await backend.fault(offline: true)
        do { _ = try await p.read(block: 0); XCTFail() } catch { }
        await backend.fault()
        let restored = try await p.read(block: 0); XCTAssertEqual(restored, payload)
    }
    func testLostAcknowledgementStopsSession() async throws {
        let backend = MemoryObjects()
        let p = try RemotePager(directory: root, key: key, backend: backend, create: true)
        await backend.fault(loseAck: true)
        do { try await p.write(block: 0, data: payload); XCTFail() } catch { }
        await backend.fault()
        do { _ = try await p.read(block: 0); XCTFail() } catch PagingError.poisoned { }
    }
    func testCorruptedRemoteObjectRejected() async throws {
        let backend = MemoryObjects()
        let p = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await p.write(block: 0, data: payload); await backend.corrupt()
        do { _ = try await p.read(block: 0); XCTFail() } catch { }
    }
}
