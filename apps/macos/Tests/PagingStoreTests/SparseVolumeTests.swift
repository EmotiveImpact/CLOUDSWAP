import XCTest
import CryptoKit
@testable import PagingStore

private actor VolumeObjects: ObjectBackend {
    var values: [String: Data] = [:]
    var failAt: Int?
    var writes = 0
    var missing = false
    var corrupt = false
    var suspend = false
    var entered = false
    var gate: CheckedContinuation<Void, Never>?
    func configure(failAt: Int? = nil, missing: Bool = false, corrupt: Bool = false, suspend: Bool = false) {
        self.failAt = failAt; self.missing = missing; self.corrupt = corrupt; self.suspend = suspend
    }
    func hasEntered() -> Bool { entered }
    func release() { gate?.resume(); gate = nil }
    func put(key: String, data: Data) async throws {
        writes += 1
        values[key] = data // An uncertain PUT can persist before losing its reply.
        if suspend { entered = true; await withCheckedContinuation { gate = $0 } }
        if writes == failAt { throw PagingError.unavailable }
    }
    func get(key: String) throws -> Data {
        if missing { throw PagingError.missing }
        if corrupt { return Data(repeating: 1, count: 16384 + 28) }
        guard let value = values[key] else { throw PagingError.missing }
        return value
    }
}

final class SparseVolumeTests: XCTestCase {
    var roots: [URL] = []
    func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(url); return url
    }
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }

    func testGigabyteSparseFileUsesOnlyWrittenPagesAndSurvivesReopen() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true)
        let file = try await volume!.create(name: "swapfile0", size: 1024 * 1024 * 1024)
        let offset = file.size - 23, payload = Data(repeating: 0x35, count: 23)
        let attr = try await volume!.write(file.id, offset: offset, data: payload)
        XCTAssertEqual(attr.size, file.size); XCTAssertEqual(attr.used, 16384 + 28)
        let hole = try await volume!.read(file.id, offset: 42, count: 65536)
        XCTAssertEqual(hole, Data(repeating: 0, count: 65536))
        try await volume!.checkpoint(); volume = nil
        let reopened = try SparseVolume(directory: directory, key: key, create: false)
        let result = try await reopened.read(file.id, offset: offset, count: 64)
        XCTAssertEqual(result, payload)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("page-") }.count, 1)
    }
    func testCrossShardPartialWritesAndSlicePreserveNeighbours() async throws {
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true)
        let file = try await volume.create(name: "scratch")
        let offset = 4 * 1024 * 1024 - 16385
        var expected = Data(repeating: 0x15, count: 65536)
        _ = try await volume.write(file.id, offset: offset, data: expected)
        let patch = Data([0, 1, 2, 3, 4]).dropFirst(2)
        _ = try await volume.write(file.id, offset: offset + 16383, data: patch)
        expected.replaceSubrange(16383..<16386, with: patch)
        let actual = try await volume.read(file.id, offset: offset, count: 65536)
        XCTAssertEqual(actual, expected)
    }
    func testShrinkAndRegrowNeverExposeOldTailOrRemovedShards() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true)
        let file = try await volume!.create(name: "swapfile0", size: 16 * 1024 * 1024)
        _ = try await volume!.write(file.id, offset: 0, data: Data(repeating: 7, count: 32768))
        _ = try await volume!.write(file.id, offset: 8 * 1024 * 1024, data: Data([9]))
        _ = try await volume!.resize(file.id, size: 16387)
        _ = try await volume!.resize(file.id, size: file.size)
        volume = nil
        let reopened = try SparseVolume(directory: directory, key: key, create: false)
        let boundary = try await reopened.read(file.id, offset: 16380, count: 20)
        XCTAssertEqual(boundary, Data(repeating: 7, count: 7) + Data(repeating: 0, count: 13))
        let removed = try await reopened.read(file.id, offset: 8 * 1024 * 1024, count: 32)
        XCTAssertEqual(removed, Data(repeating: 0, count: 32))
        _ = try await reopened.resize(file.id, size: 0)
        let grown = try await reopened.resize(file.id, size: file.size)
        XCTAssertEqual(grown.used, 0)
        let cleared = try await reopened.read(file.id, offset: 0, count: 32)
        XCTAssertEqual(cleared, Data(repeating: 0, count: 32))
    }
    func testRenameReplacementDeleteAndRecreateNeverReuseHandle() async throws {
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true)
        let a = try await volume.create(name: "a"), b = try await volume.create(name: "b")
        _ = try await volume.write(a.id, offset: 0, data: Data([1]))
        let renamed = try await volume.rename(a.id, name: "b")
        XCTAssertEqual(renamed.id, a.id)
        do { _ = try await volume.attributes(b.id); XCTFail() } catch VolumeError.missing {}
        try await volume.remove(a.id)
        let replacement = try await volume.create(name: "b")
        XCTAssertGreaterThan(replacement.id, b.id)
        do { _ = try await volume.attributes(a.id); XCTFail() } catch VolumeError.missing {}
    }
    func testLimitsBadNamesAndEmptyWriteDoNotModifyState() async throws {
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true)
        for name in ["", "../outside", ".", "a/b", String(repeating: "a", count: 65)] {
            do { _ = try await volume.create(name: name); XCTFail(name) } catch VolumeError.invalid {}
        }
        let a = try await volume.create(name: "a", size: SparseVolume.maxFileSize)
        _ = try await volume.create(name: "b", size: SparseVolume.maxFileSize)
        do { _ = try await volume.create(name: "c", size: 1); XCTFail() } catch VolumeError.capacity {}
        do { _ = try await volume.write(a.id, offset: Int.max, data: Data([1])); XCTFail() } catch VolumeError.invalid {}
        do { _ = try await volume.read(a.id, offset: 0, count: 65537); XCTFail() } catch VolumeError.invalid {}
        _ = try await volume.resize(a.id, size: 0)
        let empty = try await volume.write(a.id, offset: 1024 * 1024, data: Data())
        XCTAssertEqual(empty.size, 0)
        let eof = try await volume.read(a.id, offset: Int.max, count: 1)
        XCTAssertTrue(eof.isEmpty)
    }
    func testUncertainRemoteMultiPageWriteReopensWholePreviousCommit() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256), backend = VolumeObjects()
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true, remote: backend)
        let file = try await volume!.create(name: "a")
        let original = Data(repeating: 3, count: 32768)
        _ = try await volume!.write(file.id, offset: 0, data: original)
        await backend.configure(failAt: 4)
        do { _ = try await volume!.write(file.id, offset: 0, data: Data(repeating: 5, count: 32768)); XCTFail() } catch PagingError.unavailable {}
        do { _ = try await volume!.read(file.id, offset: 0, count: 1); XCTFail() } catch PagingError.poisoned {}
        volume = nil; await backend.configure()
        let reopened = try SparseVolume(directory: directory, key: key, create: false, remote: backend)
        let actual = try await reopened.read(file.id, offset: 0, count: 32768)
        XCTAssertEqual(actual, original)
        let intents = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("intent-") }
        XCTAssertEqual(intents.count, 4) // Includes ambiguous and uncommitted PUTs.
    }
    func testMissingCommittedObjectIsNeverASparseHole() async throws {
        let backend = VolumeObjects()
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true, remote: backend)
        let file = try await volume.create(name: "a")
        _ = try await volume.write(file.id, offset: 0, data: Data([9]))
        await backend.configure(missing: true)
        do { _ = try await volume.read(file.id, offset: 0, count: 1); XCTFail() } catch PagingError.unavailable {}
        do { try await volume.checkpoint(); XCTFail() } catch PagingError.poisoned {}
    }
    func testMirrorServesWithoutRemoteReadsButOfflineWriteFails() async throws {
        let backend = VolumeObjects()
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true, remote: backend, mirror: true)
        let file = try await volume.create(name: "a")
        _ = try await volume.write(file.id, offset: 0, data: Data([9]))
        await backend.configure(failAt: 2, missing: true)
        let bytes = try await volume.read(file.id, offset: 0, count: 1)
        XCTAssertEqual(bytes, Data([9]))
        do { _ = try await volume.write(file.id, offset: 0, data: Data([7])); XCTFail() } catch PagingError.unavailable {}
    }
    func testCatalogueRollbackFailsEvenForUnwrittenRead() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        let volume = try SparseVolume(directory: directory, key: key, create: true)
        let file = try await volume.create(name: "a", size: 8192)
        let catalogue = directory.appendingPathComponent("catalogue.enc")
        let old = try Data(contentsOf: catalogue)
        _ = try await volume.write(file.id, offset: 0, data: Data([9]))
        try old.write(to: catalogue)
        do { _ = try await volume.read(file.id, offset: 4096, count: 1); XCTFail() } catch PagingError.invalid {}
        do { try await volume.checkpoint(); XCTFail() } catch PagingError.poisoned {}
    }
    func testMissingLeafFailsCheckpointAndWrongKeyCannotReopen() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true)
        let file = try await volume!.create(name: "a")
        _ = try await volume!.write(file.id, offset: 0, data: Data([9]))
        let leaf = try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("leaf-") }!
        try FileManager.default.removeItem(at: directory.appendingPathComponent(leaf))
        do { try await volume!.checkpoint(); XCTFail() } catch PagingError.unavailable {}
        volume = nil
        XCTAssertThrowsError(try SparseVolume(directory: directory, key: SymmetricKey(size: .bits256), create: false))
    }
    func testExclusiveVerifierSurvivesRestartAndRejectsDifferentCreator() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true)
        let first = try await volume!.create(name: "a", verifier: "0102030405060708")
        volume = nil
        let reopened = try SparseVolume(directory: directory, key: key, create: false)
        let again = try await reopened.create(name: "a", verifier: "0102030405060708")
        XCTAssertEqual(first, again)
        do { _ = try await reopened.create(name: "a", verifier: "0202030405060708"); XCTFail() } catch VolumeError.exists {}
    }
    func testPayloadFromAnotherFileCannotAuthenticate() async throws {
        let directory = root()
        let volume = try SparseVolume(directory: directory, key: SymmetricKey(size: .bits256), create: true)
        let a = try await volume.create(name: "a"), b = try await volume.create(name: "b")
        _ = try await volume.write(a.id, offset: 0, data: Data([3]))
        let first = try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("page-") }!
        _ = try await volume.write(b.id, offset: 0, data: Data([9]))
        let second = try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("page-") && $0 != first }!
        try Data(contentsOf: directory.appendingPathComponent(second)).write(to: directory.appendingPathComponent(first))
        do { _ = try await volume.read(a.id, offset: 0, count: 1); XCTFail() } catch CryptoKitError.authenticationFailure {}
        do { try await volume.checkpoint(); XCTFail() } catch PagingError.poisoned {}
    }
    func testReplacedDirectoryCannotServeHolesOrAcceptWrites() async throws {
        let directory = root(), moved = root()
        let volume = try SparseVolume(directory: directory, key: SymmetricKey(size: .bits256), create: true)
        let file = try await volume.create(name: "a", size: 8192)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do { _ = try await volume.read(file.id, offset: 0, count: 1); XCTFail() } catch PagingError.unavailable {}
        do { _ = try await volume.write(file.id, offset: 0, data: Data([9])); XCTFail() } catch PagingError.poisoned {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func testSecondWriterAndWrongModeRefusedWithoutReplacingStore() async throws {
        let directory = root(), key = SymmetricKey(size: .bits256)
        var volume: SparseVolume? = try SparseVolume(directory: directory, key: key, create: true)
        _ = try await volume!.create(name: "a")
        XCTAssertThrowsError(try SparseVolume(directory: directory, key: key, create: false))
        XCTAssertThrowsError(try SparseVolume(directory: directory, key: key, create: true))
        volume = nil
        XCTAssertThrowsError(try SparseVolume(directory: directory, key: key, create: false, remote: VolumeObjects()))
        let reopened = try SparseVolume(directory: directory, key: key, create: false)
        let files = try await reopened.list()
        XCTAssertEqual(files.map(\.name), ["a"])
    }
    func testConcurrentOperationsRejectedAcrossRemoteAwait() async throws {
        let backend = VolumeObjects()
        let volume = try SparseVolume(directory: root(), key: SymmetricKey(size: .bits256), create: true, remote: backend)
        let file = try await volume.create(name: "a")
        await backend.configure(suspend: true)
        let task = Task { try await volume.write(file.id, offset: 0, data: Data([1])) }
        for _ in 0..<1000 {
            if await backend.hasEntered() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard await backend.hasEntered() else { await backend.release(); XCTFail(); return }
        do { _ = try await volume.resize(file.id, size: 0); XCTFail() } catch PagingError.busy {}
        do { _ = try await volume.list(); XCTFail() } catch PagingError.busy {}
        await backend.release(); _ = try await task.value
        let result = try await volume.read(file.id, offset: 0, count: 1)
        XCTAssertEqual(result, Data([1]))
    }
}
