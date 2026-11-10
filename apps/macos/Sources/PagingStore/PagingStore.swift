import Foundation
import CryptoKit
import Darwin

public enum PagingError: Error { case invalid, missing, busy, poisoned, unavailable }

/// Local encrypted reference backend. Process-restart recovery, not power-loss durability.
/// The caller must retain the key; no keys are written to this directory.
final class FileLock {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

public final class PagingStore {
    private let directory: URL
    private let storage: StoreDirectory
    private let key: SymmetricKey
    private var index: [String: String]
    private let mutex = NSLock()
    private let fileLock: FileLock
    private var poisoned = false
    public static let blockSize = 16384
    public static let maxBlocks = 256
    private static let indexAAD = Data("cloudswap-index-v1".utf8)

    public init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory; self.key = key; self.index = [:]
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw PagingError.unavailable }
        self.storage = try StoreDirectory(directory)
        self.fileLock = try storage.lock()
        do {
            let manifest = directory.appendingPathComponent("index.enc")
            if FileManager.default.fileExists(atPath: manifest.path) {
                let raw = try storage.read("index.enc")
                let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key, authenticating: Self.indexAAD)
                self.index = try JSONDecoder().decode([String: String].self, from: decoded)
                guard index.count <= Self.maxBlocks else { throw PagingError.invalid }
                for (block, object) in index {
                    guard let number = Int(block), number >= 0, number < Self.maxBlocks,
                          UUID(uuidString: object) != nil else { throw PagingError.invalid }
                }
            } else {
                // Existing objects without their index must never become an empty store.
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                guard names.allSatisfy({ $0 == "writer.lock" }) else { throw PagingError.invalid }
                try saveIndex([:])
            }
        } catch {
            throw error
        }
    }
    private func saveIndex(_ values: [String: String]) throws {
        let json = try JSONEncoder().encode(values)
        let encrypted = try AES.GCM.seal(json, using: key, authenticating: Self.indexAAD).combined!
        try storage.write("index.enc", data: encrypted)
    }
    public func write(block: Int, data: Data) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !poisoned else { throw PagingError.poisoned }
        guard block >= 0, block < Self.maxBlocks, data.count == Self.blockSize else { throw PagingError.invalid }
        let object = UUID().uuidString
        let aad = Data("\(block)/\(object)".utf8)
        let encrypted = try AES.GCM.seal(data, using: key, authenticating: aad).combined!
        let old = index[String(block)]
        var next = index; next[String(block)] = object
        do {
            try storage.write(object, data: encrypted)
            try saveIndex(next)
            index = next
        } catch { poisoned = true; throw error }
        if let old = old { storage.remove(old) }
    }
    public func read(block: Int) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        guard !poisoned else { throw PagingError.poisoned }
        guard block >= 0, block < Self.maxBlocks else { throw PagingError.invalid }
        guard let object = index[String(block)] else { throw PagingError.missing }
        let raw: Data
        do { raw = try storage.read(object) }
        catch { poisoned = true; throw error }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key,
                                    authenticating: Data("\(block)/\(object)".utf8))
        guard data.count == Self.blockSize else { throw PagingError.invalid }
        return data
    }
}
