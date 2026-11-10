import Foundation
import CryptoKit
import Darwin

public protocol TrialObjectBackend: ObjectBackend {
    func delete(key: String) async throws
}

/// Synthetic remote service for the menu test. No network requests are made.
public actor TrialMemoryBackend: TrialObjectBackend {
    private var objects: [String: Data] = [:]
    public init() {}
    public func put(key: String, data: Data) { objects[key] = data }
    public func get(key: String) throws -> Data {
        guard let value = objects[key] else { throw PagingError.missing }
        return value
    }
    public func delete(key: String) { objects.removeValue(forKey: key) }
    public var objectCount: Int { objects.count }
}

private actor TrialTransport: ObjectBackend {
    let upstream: TrialObjectBackend
    var offline = false
    var keys: [String] = []
    var puts = 0
    var gets = 0
    var blocked = 0
    init(_ upstream: TrialObjectBackend) { self.upstream = upstream }
    func disconnect() { offline = true }
    func put(key: String, data: Data) async throws {
        if offline { blocked += 1; throw URLError(.notConnectedToInternet) }
        keys.append(key) // Includes ambiguous acknowledgements for cleanup.
        puts += 1
        try await upstream.put(key: key, data: data)
    }
    func get(key: String) async throws -> Data {
        if offline { blocked += 1; throw URLError(.notConnectedToInternet) }
        gets += 1
        return try await upstream.get(key: key)
    }
    func cleanup() async -> [String] {
        var remaining: [String] = []
        for key in keys {
            do { try await upstream.delete(key: key) }
            catch { remaining.append(key) }
        }
        return remaining
    }
}

public struct TieredTrialReport: Codable, Sendable {
    public var schemaVersion = 1
    public var storageChecksPassed = false
    public var systemSwapTested = false
    public var physicalDisconnectTested = false
    public var directory: String
    public var logicalBytes = 0
    public var localAllocatedBytes: Int64 = 0
    public var remotePuts = 0
    public var remoteGets = 0
    public var blockedOperations = 0
    public var remoteReadP95Milliseconds = 0.0
    public var mirrorReadP95Milliseconds = 0.0
    public var stages: [String] = []
    public var failedStage: String?
    public var localFilesRemoved = false
    public var remoteObjectsRemaining: [String] = []
    public var passed: Bool { storageChecksPassed && localFilesRemoved && remoteObjectsRemaining.isEmpty }
}

/// Bounded synthetic trial. Keys live only for this run; reopen is not process restart.
public enum TieredTrial {
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    static func p95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }
    public static func run(parent: URL, backend: TrialObjectBackend, blocks: Int = 64) async -> TieredTrialReport {
        let root = parent.appendingPathComponent("cloudswap-tiered-" + UUID().uuidString)
        var report = TieredTrialReport(directory: root.path)
        guard blocks > 0, blocks <= PagingStore.maxBlocks else {
            report.failedStage = "configuration"; return report
        }
        let transport = TrialTransport(backend)
        let key = SymmetricKey(size: .bits256)
        var pager: RemotePager?
        var ownedDirectory: StoreDirectory?
        var stage = "create"
        do {
            // Parent must already exist. Never create or overwrite a user-selected store.
            pager = try RemotePager(directory: root, key: key, backend: transport, create: true, mirror: true)
            ownedDirectory = try StoreDirectory(root)
            stage = "upload_and_mirror"
            var hashes: [Data] = []
            for block in 0..<blocks {
                try Task.checkCancellation()
                let bytes = Data((0..<PagingStore.blockSize).map { _ in UInt8.random(in: 0...255) })
                hashes.append(digest(bytes))
                try await pager!.write(block: block, data: bytes)
            }
            report.logicalBytes = blocks * PagingStore.blockSize
            report.stages.append(stage)
            pager = nil
            stage = "remote_read_after_reopen"
            pager = try RemotePager(directory: root, key: key, backend: transport)
            var remoteTimes: [Double] = []
            for block in (0..<blocks).reversed() {
                let start = DispatchTime.now().uptimeNanoseconds
                guard digest(try await pager!.read(block: block)) == hashes[block] else { throw PagingError.invalid }
                remoteTimes.append(milliseconds(start))
            }
            report.remoteReadP95Milliseconds = p95(remoteTimes)
            report.stages.append(stage)
            pager = nil
            await transport.disconnect()
            stage = "offline_mirror_after_reopen"
            pager = try RemotePager(directory: root, key: key, backend: transport, mirror: true)
            var mirrorTimes: [Double] = []
            for block in 0..<blocks {
                let start = DispatchTime.now().uptimeNanoseconds
                guard digest(try await pager!.read(block: block)) == hashes[block] else { throw PagingError.invalid }
                mirrorTimes.append(milliseconds(start))
            }
            report.mirrorReadP95Milliseconds = p95(mirrorTimes)
            report.stages.append(stage)
            stage = "offline_write_stops_session"
            do {
                try await pager!.write(block: 0, data: Data(repeating: 0, count: PagingStore.blockSize))
                throw PagingError.invalid
            } catch let error as URLError where error.code == .notConnectedToInternet { }
            do {
                _ = try await pager!.read(block: 0)
                throw PagingError.invalid
            } catch PagingError.poisoned { }
            report.stages.append(stage)
            pager = nil
            stage = "recover_last_committed_page"
            pager = try RemotePager(directory: root, key: key, backend: transport, mirror: true)
            guard digest(try await pager!.read(block: 0)) == hashes[0] else { throw PagingError.invalid }
            report.localAllocatedBytes = try ownedDirectory!.trialAllocation()
            report.stages.append(stage)
            report.storageChecksPassed = true
        } catch { report.failedStage = stage }
        pager = nil
        report.remotePuts = await transport.puts
        report.remoteGets = await transport.gets
        report.blockedOperations = await transport.blocked
        report.remoteObjectsRemaining = await transport.cleanup()
        // Remove only this trial's regular files through its pinned directory descriptor.
        // Keep the empty directory: no path-based recursive deletion after a drive disappears.
        if let directory = ownedDirectory {
            do { try directory.removeTrialFiles(); report.localFilesRemoved = true }
            catch { report.localFilesRemoved = false }
        }
        return report
    }
}

extension StoreDirectory {
    private func trialFiles() throws -> [(String, Int64)] {
        try validate()
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        var result: [(String, Int64)] = []
        for name in names {
            guard name == "writer.lock" || name == "remote-index.enc" || UUID(uuidString: name) != nil else { throw PagingError.invalid }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { throw PagingError.invalid }
            result.append((name, Int64(info.st_blocks) * 512))
        }
        try validate()
        return result
    }
    func trialAllocation() throws -> Int64 { try trialFiles().reduce(0) { $0 + $1.1 } }
    func removeTrialFiles() throws {
        let files = try trialFiles()
        for (name, _) in files {
            guard unlinkat(fd, name, 0) == 0 else { throw PagingError.unavailable }
        }
        guard fsync(fd) == 0 else { throw PagingError.unavailable }
        try validate()
    }
}
