import Foundation
import CryptoKit
import Darwin

public protocol ObjectBackend {
    func put(key: String, data: Data) async throws
    func get(key: String) async throws -> Data
}

/// Cloud payloads with a small encrypted local index. No system paging hooks.
/// Busy rejects overlapping operations, including actor re-entry during network awaits.
public actor RemotePager {
    let directory: URL
    let key: SymmetricKey
    let backend: ObjectBackend
    let fileLock: FileLock
    var index: [String: String]
    var busy = false
    var poisoned = false
    static let aad = Data("cloudswap-remote-index-v1".utf8)

    public init(directory: URL, key: SymmetricKey, backend: ObjectBackend, create: Bool = false) throws {
        self.directory = directory; self.key = key; self.backend = backend
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let fd = Darwin.open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PagingError.busy }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw PagingError.busy }
        fileLock = FileLock(fd)
        let path = directory.appendingPathComponent("remote-index.enc")
        if create {
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy({ $0 == "writer.lock" }) else { throw PagingError.invalid }
            index = [:]
            try Self.save([:], directory: directory, key: key)
        } else {
            let bytes = try Data(contentsOf: path)
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Self.aad)
            index = try JSONDecoder().decode([String: String].self, from: decoded)
            guard index.count <= PagingStore.maxBlocks else { throw PagingError.invalid }
            for (block, object) in index {
                guard let i = Int(block), i >= 0, i < PagingStore.maxBlocks,
                      UUID(uuidString: object) != nil else { throw PagingError.invalid }
            }
        }
    }
    static func save(_ index: [String: String], directory: URL, key: SymmetricKey) throws {
        let data = try JSONEncoder().encode(index)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad).combined!
        try sealed.write(to: directory.appendingPathComponent("remote-index.enc"), options: .atomic)
    }
    func begin(_ block: Int) throws {
        guard !poisoned else { throw PagingError.poisoned }
        guard !busy else { throw PagingError.busy }
        guard block >= 0, block < PagingStore.maxBlocks else { throw PagingError.invalid }
        busy = true
    }
    public func write(block: Int, data: Data) async throws {
        try begin(block); defer { busy = false }
        guard data.count == PagingStore.blockSize else { throw PagingError.invalid }
        let object = UUID().uuidString.lowercased()
        let payload = try AES.GCM.seal(data, using: key, authenticating: Data("\(block)/\(object)".utf8)).combined!
        var next = index; next[String(block)] = object
        do {
            try await backend.put(key: "cloudswap-lab/\(object)/probe", data: payload)
            try Self.save(next, directory: directory, key: key)
            index = next
        } catch { poisoned = true; throw error }
    }
    public func read(block: Int) async throws -> Data {
        try begin(block); defer { busy = false }
        guard let object = index[String(block)] else { throw PagingError.missing }
        let bytes = try await backend.get(key: "cloudswap-lab/\(object)/probe")
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key,
                                    authenticating: Data("\(block)/\(object)".utf8))
        guard data.count == PagingStore.blockSize else { throw PagingError.invalid }
        return data
    }
}
