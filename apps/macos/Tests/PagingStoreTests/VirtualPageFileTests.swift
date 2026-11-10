import XCTest
import CryptoKit
@testable import PagingStore

private actor TestPages: FilePageBackend {
    var pages: [Int: Data] = [:]
    var failBlock: Int?
    var failFlush = false
    var gate: CheckedContinuation<Void, Never>?
    var entered = false
    var suspend = false
    func configure(failBlock: Int? = nil, failFlush: Bool = false, suspend: Bool = false) {
        self.failBlock = failBlock; self.failFlush = failFlush; self.suspend = suspend
    }
    func hasEntered() -> Bool { entered }
    func release() { gate?.resume(); gate = nil }
    func read(block: Int) throws -> Data {
        guard let data = pages[block] else { throw PagingError.missing }
        return data
    }
    func write(block: Int, data: Data) async throws {
        if suspend {
            entered = true
            await withCheckedContinuation { gate = $0 }
        }
        if failBlock == block { throw PagingError.unavailable }
        pages[block] = data
    }
    func checkpoint() throws { if failFlush { throw PagingError.unavailable } }
}
private actor VanishingObjects: ObjectBackend {
    func put(key: String, data: Data) {}
    func get(key: String) throws -> Data { throw PagingError.missing }
}
final class VirtualPageFileTests: XCTestCase {
    func testRemoteFileReadRecoversAfterSimulatedOutage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = MemoryObjects()
        let pager = try RemotePager(directory: root, key: SymmetricKey(size: .bits256), backend: objects, create: true)
        let file = VirtualPageFile(backend: pager)
        let payload = Data(repeating: 0x39, count: 40)
        _ = try await file.write(offset: 16380, data: payload)
        await objects.fault(offline: true)
        do { _ = try await file.read(offset: 16380, count: 40); XCTFail() } catch is URLError {}
        await objects.fault()
        let recovered = try await file.read(offset: 16380, count: 40)
        XCTAssertEqual(recovered, payload)
    }
    func testMirroredFileReadsOfflineAndRejectsOfflineWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = MemoryObjects()
        let pager = try RemotePager(directory: root, key: SymmetricKey(size: .bits256), backend: objects, create: true, mirror: true)
        let file = VirtualPageFile(backend: pager)
        let payload = Data(repeating: 0x39, count: 40)
        _ = try await file.write(offset: 16380, data: payload)
        await objects.fault(offline: true)
        let recovered = try await file.read(offset: 16380, count: 40)
        XCTAssertEqual(recovered, payload)
        try await file.flush()
        do { _ = try await file.write(offset: 16380, data: Data([7])); XCTFail() } catch is URLError {}
        await objects.fault()
        do { _ = try await file.read(offset: 16380, count: 40); XCTFail() } catch PagingError.poisoned {}
    }
    func testUnwrittenAndEOF() async throws {
        let file = VirtualPageFile(backend: TestPages())
        let hole = try await file.read(offset: 16380, count: 20)
        XCTAssertEqual(hole, Data(repeating: 0, count: 20))
        let tail = try await file.read(offset: VirtualPageFile.capacity - 2, count: 20)
        XCTAssertEqual(tail.count, 2)
        let eof = try await file.read(offset: Int.max, count: 20)
        XCTAssertTrue(eof.isEmpty)
    }
    func testOverlappingUnalignedWritesPreserveNeighbours() async throws {
        let file = VirtualPageFile(backend: TestPages())
        var expected = Data(repeating: 0x17, count: 32768)
        _ = try await file.write(offset: 0, data: expected)
        let patch = Data(repeating: 0x34, count: 31)
        _ = try await file.write(offset: 16380, data: patch)
        expected.replaceSubrange(16380..<16411, with: patch)
        let result = try await file.read(offset: 0, count: expected.count)
        XCTAssertEqual(result, expected)
    }
    func testDataSliceWithNonzeroStartIndexAcrossPageBoundary() async throws {
        let file = VirtualPageFile(backend: TestPages())
        let slice = Data([0, 1, 2, 3, 4]).dropFirst(2)
        XCTAssertEqual(slice.startIndex, 2)
        _ = try await file.write(offset: 16383, data: slice)
        let result = try await file.read(offset: 16382, count: 5)
        XCTAssertEqual(result, Data([0, 2, 3, 4, 0]))
    }
    func testInvalidRangesDoNotPoison() async throws {
        let file = VirtualPageFile(backend: TestPages())
        for (offset, count) in [(-1, 1), (0, -1), (0, 65537)] {
            do { _ = try await file.read(offset: offset, count: count); XCTFail() } catch PagingError.invalid {}
        }
        for offset in [-1, VirtualPageFile.capacity, Int.max] {
            do { _ = try await file.write(offset: offset, data: Data([1])); XCTFail() } catch PagingError.invalid {}
        }
        let count = try await file.write(offset: 0, data: Data([7]))
        XCTAssertEqual(count, 1)
    }
    func testPartialWriteFailureRequiresReopen() async throws {
        let backend = TestPages()
        await backend.configure(failBlock: 1)
        let file = VirtualPageFile(backend: backend)
        do { _ = try await file.write(offset: 0, data: Data(repeating: 5, count: 32768)); XCTFail() }
        catch PagingError.unavailable {}
        let committed = try await backend.read(block: 0)
        XCTAssertEqual(committed.count, 16384)
        do { _ = try await file.read(offset: 0, count: 1); XCTFail() } catch PagingError.poisoned {}
        do { try await file.flush(); XCTFail() } catch PagingError.poisoned {}
    }
    func testCheckpointFailureStopsFurtherOperations() async throws {
        let backend = TestPages()
        await backend.configure(failFlush: true)
        let file = VirtualPageFile(backend: backend)
        do { try await file.flush(); XCTFail() } catch PagingError.unavailable {}
        do { _ = try await file.write(offset: 0, data: Data([5])); XCTFail() } catch PagingError.poisoned {}
    }
    func testConcurrentReadModifyWriteRejectedDuringAwait() async throws {
        let backend = TestPages()
        await backend.configure(suspend: true)
        let file = VirtualPageFile(backend: backend)
        let task = Task { try await file.write(offset: 0, data: Data([5])) }
        for _ in 0..<1000 {
            if await backend.hasEntered() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard await backend.hasEntered() else {
            await backend.configure()
            await backend.release()
            XCTFail("Write did not reach the await gate")
            return
        }
        do { _ = try await file.write(offset: 1, data: Data([9])); XCTFail() } catch PagingError.busy {}
        do { _ = try await file.read(offset: 0, count: 2); XCTFail() } catch PagingError.busy {}
        await backend.release()
        _ = try await task.value
        let result = try await file.read(offset: 0, count: 2)
        XCTAssertEqual(result, Data([5, 0]))
    }
    func testLostCommittedRemoteObjectIsNeverZeroFilled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pager = try RemotePager(directory: root, key: SymmetricKey(size: .bits256), backend: VanishingObjects(), create: true)
        let file = VirtualPageFile(backend: pager)
        _ = try await file.write(offset: 0, data: Data(repeating: 5, count: 16384))
        do { _ = try await file.read(offset: 0, count: 1); XCTFail("Lost data returned as a hole") }
        catch PagingError.unavailable {}
    }
    func testReplacedDirectoryCannotReturnUnwrittenZeros() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = root.appendingPathExtension("detached")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let store = try PagingStore(directory: root, key: SymmetricKey(size: .bits256))
        let file = VirtualPageFile(backend: store)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do { _ = try await file.read(offset: 0, count: 1); XCTFail() } catch PagingError.unavailable {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
