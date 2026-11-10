import XCTest
@testable import PagingStore

actor FailingTrialBackend: TrialObjectBackend {
    enum Failure { case put, corruptRead, cleanup, lostAcknowledgement }
    let failure: Failure
    var objects: [String: Data] = [:]
    init(_ failure: Failure) { self.failure = failure }
    func put(key: String, data: Data) throws {
        if failure == .put { throw PagingError.unavailable }
        objects[key] = data
        if failure == .lostAcknowledgement { throw URLError(.timedOut) }
    }
    func get(key: String) throws -> Data {
        if failure == .corruptRead { return Data(repeating: 0, count: 30) }
        guard let bytes = objects[key] else { throw PagingError.missing }
        return bytes
    }
    func delete(key: String) throws {
        if failure == .cleanup { throw PagingError.unavailable }
        objects.removeValue(forKey: key)
    }
    var count: Int { objects.count }
}

actor ReplacingTrialBackend: TrialObjectBackend {
    let parent: URL
    init(_ parent: URL) { self.parent = parent }
    func put(key: String, data: Data) throws {
        let root = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first!
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("detached"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("preserve".utf8).write(to: root.appendingPathComponent("user-file"))
    }
    func get(key: String) throws -> Data { throw PagingError.unavailable }
    func delete(key: String) {}
}

final class TieredTrialTests: XCTestCase {
    var parent: URL!
    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: parent) }

    func testCombinedTrialVerifiesOfflineRecoveryWithoutRemoteReads() async throws {
        let backend = TrialMemoryBackend()
        let report = await TieredTrial.run(parent: parent, backend: backend, blocks: 4)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.remotePuts, 4)
        XCTAssertEqual(report.remoteGets, 4) // No extra remote reads during mirror recovery.
        XCTAssertEqual(report.blockedOperations, 1) // Failed offline write, not a read.
        XCTAssertEqual(report.stages.count, 5)
        XCTAssertGreaterThan(report.localAllocatedBytes, Int64(report.logicalBytes))
        XCTAssertFalse(report.systemSwapTested)
        XCTAssertFalse(report.physicalDisconnectTested)
        let count = await backend.objectCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: report.directory), [])
    }
    func testCorruptRemoteCannotBeHiddenByGoodMirror() async throws {
        let report = await TieredTrial.run(parent: parent, backend: FailingTrialBackend(.corruptRead), blocks: 2)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failedStage, "remote_read_after_reopen")
        XCTAssertTrue(report.localFilesRemoved)
        XCTAssertTrue(report.remoteObjectsRemaining.isEmpty)
    }
    func testLostAcknowledgementStillCleansAttemptedObject() async throws {
        let backend = FailingTrialBackend(.lostAcknowledgement)
        let report = await TieredTrial.run(parent: parent, backend: backend, blocks: 2)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failedStage, "upload_and_mirror")
        XCTAssertTrue(report.localFilesRemoved)
        let remaining = await backend.count
        XCTAssertEqual(remaining, 0)
    }
    func testCleanupFailureIsNotReportedAsPassed() async throws {
        let report = await TieredTrial.run(parent: parent, backend: FailingTrialBackend(.cleanup), blocks: 2)
        XCTAssertTrue(report.storageChecksPassed)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.remoteObjectsRemaining.count, 2)
        XCTAssertTrue(report.localFilesRemoved)
    }
    func testInvalidBoundCreatesNoFiles() async throws {
        for blocks in [0, PagingStore.maxBlocks + 1] {
            let report = await TieredTrial.run(parent: parent, backend: TrialMemoryBackend(), blocks: blocks)
            XCTAssertFalse(report.passed)
            XCTAssertEqual(report.failedStage, "configuration")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
    func testUnrelatedParentFilesArePreserved() async throws {
        let sentinel = parent.appendingPathComponent("existing-data")
        try Data("keep".utf8).write(to: sentinel)
        let report = await TieredTrial.run(parent: parent, backend: TrialMemoryBackend(), blocks: 1)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testReplacedDirectoryIsNotCleanedOrUsed() async throws {
        let report = await TieredTrial.run(parent: parent, backend: ReplacingTrialBackend(parent), blocks: 1)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failedStage, "upload_and_mirror")
        XCTAssertFalse(report.localFilesRemoved)
        let replacement = URL(fileURLWithPath: report.directory).appendingPathComponent("user-file")
        XCTAssertEqual(try Data(contentsOf: replacement), Data("preserve".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("detached").path).isEmpty)
    }
    func testMissingParentIsNotCreated() async throws {
        let missing = parent.appendingPathComponent("missing")
        let report = await TieredTrial.run(parent: missing, backend: TrialMemoryBackend(), blocks: 1)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failedStage, "create")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

}
