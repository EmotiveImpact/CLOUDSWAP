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
    let storage: StoreDirectory
    let key: SymmetricKey
    let backend: ObjectBackend
    let mirror: Bool
    let fileLock: FileLock
    var index: [String: String]
    var busy = false
    var poisoned = false
    // CryptoKit combined AES-GCM: 12-byte nonce + fixed page + 16-byte tag.
    static let encryptedPageSize = PagingStore.blockSize + 28
    static func openPage(_ bytes: Data, key: SymmetricKey, block: String, object: String) throws -> Data {
        guard bytes.count == encryptedPageSize else { throw PagingError.invalid }
        let page = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key,
                                    authenticating: Data("\(block)/\(object)".utf8))
        guard page.count == PagingStore.blockSize else { throw PagingError.invalid }
        return page
    }
    static let aad = Data("cloudswap-remote-index-v1".utf8)

    public init(directory: URL, key: SymmetricKey, backend: ObjectBackend, create: Bool = false, mirror: Bool = false) throws {
        self.directory = directory; self.key = key; self.backend = backend; self.mirror = mirror
        if create {
            guard mkdir(directory.path, 0o700) == 0 else { throw PagingError.unavailable }
        }
        let storage = try StoreDirectory(directory)
        self.storage = storage
        fileLock = try storage.lock()
        if create {
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy({ $0 == "writer.lock" }) else { throw PagingError.invalid }
            index = [:]
            try Self.save([:], storage: storage, key: key)
        } else {
            let bytes = try storage.read("remote-index.enc")
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Self.aad)
            index = try JSONDecoder().decode([String: String].self, from: decoded)
            guard index.count <= PagingStore.maxBlocks else { throw PagingError.invalid }
            for (block, object) in index {
                guard let i = Int(block), i >= 0, i < PagingStore.maxBlocks,
                      UUID(uuidString: object) != nil else { throw PagingError.invalid }
            }
        }
        if mirror {
            // Reopening in protected mode requires every committed page to be present.
            for (block, object) in index {
                let bytes = try storage.read(object)
                _ = try Self.openPage(bytes, key: key, block: block, object: object)
            }
        }
    }
    public func localProtectionBytes() -> Int {
        mirror ? index.count * (PagingStore.blockSize + 28) : 0
    }
    static func save(_ index: [String: String], storage: StoreDirectory, key: SymmetricKey) throws {
        let data = try JSONEncoder().encode(index)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad).combined!
        try storage.write("remote-index.enc", data: sealed)
    }
    func begin(_ block: Int) throws {
        guard !poisoned else { throw PagingError.poisoned }
        guard !busy else { throw PagingError.busy }
        guard block >= 0, block < PagingStore.maxBlocks else { throw PagingError.invalid }
        do { try storage.validate() } catch { poisoned = true; throw error }
        busy = true
    }
    public func write(block: Int, data: Data) async throws {
        try begin(block); defer { busy = false }
        guard data.count == PagingStore.blockSize else { throw PagingError.invalid }
        let object = UUID().uuidString.lowercased()
        let payload = try AES.GCM.seal(data, using: key, authenticating: Data("\(block)/\(object)".utf8)).combined!
        var next = index; next[String(block)] = object
        do {
            if mirror { try storage.write(object, data: payload) }
            try await backend.put(key: "cloudswap-lab/\(object)/probe", data: payload)
            try Self.save(next, storage: storage, key: key)
            let old = index[String(block)]
            index = next
            if mirror, let old = old { storage.remove(old) }
        } catch { poisoned = true; throw error }
    }
    public func checkpoint() throws {
        guard !poisoned else { throw PagingError.poisoned }
        guard !busy else { throw PagingError.busy }
        do {
            let bytes = try storage.read("remote-index.enc")
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Self.aad)
            let persisted = try JSONDecoder().decode([String: String].self, from: plain)
            guard persisted == index else { throw PagingError.invalid }
        } catch { poisoned = true; throw error }
    }
    public func read(block: Int) async throws -> Data {
        try begin(block); defer { busy = false }
        guard let object = index[String(block)] else { throw PagingError.missing }
        let bytes: Data
        if mirror {
            do { bytes = try storage.read(object) }
            catch { poisoned = true; throw error }
        } else {
            do { bytes = try await backend.get(key: "cloudswap-lab/\(object)/probe") }
            // Missing is reserved for an unwritten logical page. A committed
            // object's disappearance must never be presented as a zero-filled hole.
            catch PagingError.missing { throw PagingError.unavailable }
        }
        do { try storage.validate() } catch { poisoned = true; throw error }
        return try Self.openPage(bytes, key: key, block: String(block), object: object)
    }
}
