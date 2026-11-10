import XCTest
import CryptoKit
@testable import PagingStore

final class PagingStoreTests: XCTestCase {
    var root: URL!
    let key = SymmetricKey(size: .bits256)
    let data = Data(repeating: 0xa5, count: PagingStore.blockSize)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func create() throws -> PagingStore { try PagingStore(directory: root, key: key) }
    func testReopenPreservesData() throws {
        var store: PagingStore? = try create()
        try store!.write(block: 2, data: data); store = nil
        let reopened = try create()
        XCTAssertEqual(try reopened.read(block: 2), data)
    }
    func testWrongKeyFailsClosed() throws {
        var store: PagingStore? = try create()
        try store!.write(block: 0, data: data); store = nil
        XCTAssertThrowsError(try PagingStore(directory: root, key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try create().read(block: 0), data)
    }
    func testConcurrentWriterRejected() throws {
        let store = try create()
        XCTAssertThrowsError(try create())
        try store.write(block: 0, data: data)
    }
    func testOverwriteAndReopen() throws {
        var store: PagingStore? = try create()
        try store!.write(block: 0, data: data)
        let replacement = Data(repeating: 7, count: PagingStore.blockSize)
        try store!.write(block: 0, data: replacement); store = nil
        XCTAssertEqual(try create().read(block: 0), replacement)
    }
    func testCorruptionRejected() throws {
        let store = try create(); try store.write(block: 0, data: data)
        let object = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { UUID(uuidString: $0.lastPathComponent) != nil }!
        var bytes = try Data(contentsOf: object); bytes[20] ^= 1; try bytes.write(to: object)
        XCTAssertThrowsError(try store.read(block: 0))
    }
    func testMissingIndexDoesNotResetData() throws {
        var store: PagingStore? = try create(); try store!.write(block: 0, data: data); store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.enc"))
        XCTAssertThrowsError(try create())
    }
    func testBoundsAndMissing() throws {
        let store = try create()
        XCTAssertThrowsError(try store.read(block: 0))
        XCTAssertThrowsError(try store.write(block: -1, data: data))
        XCTAssertThrowsError(try store.write(block: PagingStore.maxBlocks, data: data))
        XCTAssertThrowsError(try store.write(block: 0, data: Data([1])))
    }
    func testReplacedDirectoryNeverReceivesWrites() throws {
        let store = try create()
        try store.write(block: 0, data: data)
        let moved = root.appendingPathExtension("detached")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.write(block: 1, data: data))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertThrowsError(try store.read(block: 0))
    }
    func testDisconnectRequiresReopenEvenAfterPathReturns() throws {
        var store: PagingStore? = try create()
        try store!.write(block: 0, data: data)
        let moved = root.appendingPathExtension("detached")
        try FileManager.default.moveItem(at: root, to: moved)
        XCTAssertThrowsError(try store!.read(block: 0))
        try FileManager.default.moveItem(at: moved, to: root)
        XCTAssertThrowsError(try store!.read(block: 0))
        store = nil
        XCTAssertEqual(try create().read(block: 0), data)
    }
    func testObjectSymlinkRejected() throws {
        let store = try create()
        try store.write(block: 0, data: data)
        let object = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { UUID(uuidString: $0.lastPathComponent) != nil }!
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.moveItem(at: object, to: copy)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: copy)
        XCTAssertThrowsError(try store.read(block: 0))
    }

}
