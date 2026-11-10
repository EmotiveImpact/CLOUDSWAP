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
    func snapshot() -> [String: Data] { objects }
    func replace(_ replacement: [String: Data]) { objects = replacement }
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
    func testReplacedIndexDirectoryStopsSession() async throws {
        let backend = MemoryObjects()
        var pager: RemotePager? = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager!.write(block: 0, data: payload)
        let moved = root.appendingPathExtension("detached")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do { try await pager!.write(block: 1, data: payload); XCTFail("Replacement accepted") }
        catch PagingError.unavailable { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: moved, to: root)
        do { _ = try await pager!.read(block: 0); XCTFail("Session resumed without reopen") }
        catch PagingError.poisoned { }
        pager = nil
        let reopened = try RemotePager(directory: root, key: key, backend: backend)
        let restored = try await reopened.read(block: 0)
        XCTAssertEqual(restored, payload)
    }

    func testMirrorSurvivesOfflineReopenAndReportsBytes() async throws {
        let backend = MemoryObjects()
        var pager: RemotePager? = try RemotePager(directory: root, key: key, backend: backend, create: true, mirror: true)
        try await pager!.write(block: 0, data: payload)
        let replacement = Data(repeating: 0x55, count: PagingStore.blockSize)
        try await pager!.write(block: 0, data: replacement)
        let bytes = await pager!.localProtectionBytes()
        XCTAssertEqual(bytes, PagingStore.blockSize + 28)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
        pager = nil
        await backend.fault(offline: true)
        let reopened = try RemotePager(directory: root, key: key, backend: backend, mirror: true)
        let restored = try await reopened.read(block: 0)
        XCTAssertEqual(restored, replacement)
    }
    func testMirrorCannotBeEnabledWithoutLocalPages() async throws {
        let backend = MemoryObjects()
        var pager: RemotePager? = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager!.write(block: 0, data: payload)
        pager = nil
        XCTAssertThrowsError(try RemotePager(directory: root, key: key, backend: backend, mirror: true))
    }
    func testCorruptMirrorFailsInsteadOfServingBadPage() async throws {
        let backend = MemoryObjects()
        let pager = try RemotePager(directory: root, key: key, backend: backend, create: true, mirror: true)
        try await pager.write(block: 0, data: payload)
        let object = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { UUID(uuidString: $0.lastPathComponent) != nil }!
        try Data(repeating: 0, count: 100).write(to: object)
        await backend.fault(offline: true)
        do { _ = try await pager.read(block: 0); XCTFail("Corrupt mirror accepted") } catch { }
    }

    func testMissingCommittedPageFailsAndCanRecover() async throws {
        let backend = MemoryObjects()
        let pager = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager.write(block: 0, data: payload)
        let original = await backend.snapshot()
        await backend.replace([:])
        do { _ = try await pager.read(block: 0); XCTFail("Missing page accepted") }
        catch PagingError.unavailable { }
        await backend.replace(original)
        let restored = try await pager.read(block: 0)
        XCTAssertEqual(restored, payload)
    }
    func testRemoteCheckpointRejectsAuthenticatedIndexRollback() async throws {
        let pager = try RemotePager(directory: root, key: key, backend: MemoryObjects(), create: true)
        try await pager.write(block: 0, data: payload)
        let manifest = root.appendingPathComponent("remote-index.enc")
        let old = try Data(contentsOf: manifest)
        try await pager.write(block: 1, data: payload)
        try old.write(to: manifest)
        do { try await pager.checkpoint(); XCTFail() } catch PagingError.invalid {}
        do { _ = try await pager.read(block: 0); XCTFail() } catch PagingError.poisoned {}
    }
    func testRemoteCheckpointRejectsMissingIndex() async throws {
        let pager = try RemotePager(directory: root, key: key, backend: MemoryObjects(), create: true)
        try await pager.write(block: 0, data: payload)
        try FileManager.default.removeItem(at: root.appendingPathComponent("remote-index.enc"))
        do { try await pager.checkpoint(); XCTFail() } catch PagingError.unavailable {}
        do { _ = try await pager.read(block: 0); XCTFail() } catch PagingError.poisoned {}
    }
    func testTruncatedAndOversizedPagesAreRejected() async throws {
        let backend = MemoryObjects()
        let pager = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager.write(block: 0, data: payload)
        let original = await backend.snapshot()
        for size in [0, 27, PagingStore.blockSize + 27, PagingStore.blockSize + 29] {
            await backend.replace(original.mapValues { Data($0.prefix(size)) + Data(repeating: 0, count: max(0, size - $0.count)) })
            do { _ = try await pager.read(block: 0); XCTFail("Invalid length accepted") }
            catch PagingError.invalid { }
        }
        await backend.replace(original)
        let restored = try await pager.read(block: 0)
        XCTAssertEqual(restored, payload)
    }
    func testOldGenerationCannotReplaceCurrentPage() async throws {
        let backend = MemoryObjects()
        let pager = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager.write(block: 0, data: payload)
        let old = await backend.snapshot().values.first!
        let replacement = Data(repeating: 0x33, count: PagingStore.blockSize)
        try await pager.write(block: 0, data: replacement)
        let current = await backend.snapshot()
        await backend.replace(current.mapValues { _ in old })
        do { _ = try await pager.read(block: 0); XCTFail("Stale generation accepted") } catch { }
        await backend.replace(current)
        let restored = try await pager.read(block: 0)
        XCTAssertEqual(restored, replacement)
    }
    func testAnotherBlocksCiphertextCannotBeSubstituted() async throws {
        let backend = MemoryObjects()
        let pager = try RemotePager(directory: root, key: key, backend: backend, create: true)
        try await pager.write(block: 0, data: payload)
        let first = await backend.snapshot().values.first!
        try await pager.write(block: 1, data: payload)
        let originals = await backend.snapshot()
        await backend.replace(originals.mapValues { _ in first })
        do { _ = try await pager.read(block: 1); XCTFail("Wrong block accepted") } catch { }
    }

}
