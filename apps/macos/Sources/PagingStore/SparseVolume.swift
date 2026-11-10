import Foundation
import CryptoKit
import Darwin

public enum VolumeError: Error { case invalid, missing, exists, capacity }

/// Synthetic-volume laboratory. Immutable encrypted pages/leaves and one atomic
/// catalogue commit. Retired objects are retained; a hard object limit bounds the
/// experiment. This is process-restart recovery, not power-loss certification.
public actor SparseVolume {
    public static let maxFileSize = 2 * 1024 * 1024 * 1024
    public static let capacity = 4 * 1024 * 1024 * 1024
    public static let maxFiles = 8
    public static let maxObjects = 16_384
    public static let pageSize = 16384
    public static let maxRequest = 65536
    static let shardSize = pageSize * 256
    static let catalogueLimit = 262144
    static let catalogueAAD = Data("cloudswap-sparse-catalogue-v1".utf8)

    public struct Attributes: Codable, Equatable {
        public var id: UInt64
        public var name: String
        public var size: Int
        public var mode: UInt32
        public var uid: UInt32
        public var gid: UInt32
        public var modified: UInt64
        public var accessed: UInt64
        public var changed: UInt64
        public var used: Int
    }
    struct LeafRef: Codable, Equatable { var object: String; var count: Int }
    struct Entry: Codable, Equatable {
        var attributes: Attributes
        var leaves: [String: LeafRef]
        var verifier: String? = nil
    }
    struct Catalogue: Codable, Equatable {
        var version = 1
        var volume: String
        var mode: String
        var nextID: UInt64 = 2
        var generation: UInt64 = 0
        var entries: [String: Entry] = [:]
    }
    private let storage: StoreDirectory
    private let lock: FileLock
    private let key: SymmetricKey
    private let remote: ObjectBackend?
    private let mirror: Bool
    private var catalogue: Catalogue
    private var expectedDigest: Data
    private var objects: Int
    private var busy = false
    private var poisoned = false

    public init(directory: URL, key: SymmetricKey, create: Bool,
                remote: ObjectBackend? = nil, mirror: Bool = false) throws {
        guard !mirror || remote != nil else { throw VolumeError.invalid }
        if create { guard mkdir(directory.path, 0o700) == 0 else { throw PagingError.unavailable } }
        storage = try StoreDirectory(directory)
        lock = try storage.lock()
        self.key = key; self.remote = remote; self.mirror = mirror
        let mode = remote == nil ? "local" : (mirror ? "mirror" : "remote")
        // Bound directory enumeration as well as the live catalogue. Every new
        // object has a local page/intent/leaf entry, including uncertain PUTs.
        let names = try Self.inventory(storage)
        objects = names.filter { $0 != "catalogue.enc" && $0 != "writer.lock" }.count
        if create {
            guard names == ["writer.lock"] else { throw VolumeError.invalid }
            catalogue = Catalogue(volume: UUID().uuidString.lowercased(), mode: mode)
            let data = try Self.seal(catalogue, key: key, aad: Self.catalogueAAD)
            try storage.write("catalogue.enc", data: data)
            expectedDigest = Data(SHA256.hash(data: data))
        } else {
            let data = try storage.read("catalogue.enc", limit: Self.catalogueLimit)
            catalogue = try Self.open(Catalogue.self, data: data, key: key, aad: Self.catalogueAAD)
            try Self.validate(catalogue, mode: mode)
            expectedDigest = Data(SHA256.hash(data: data))
        }
    }
    private static func inventory(_ storage: StoreDirectory) throws -> [String] {
        try storage.validate()
        let descriptor = dup(storage.fd)
        guard descriptor >= 0 else { throw PagingError.unavailable }
        guard let directory = fdopendir(descriptor) else { Darwin.close(descriptor); throw PagingError.unavailable }
        defer { closedir(directory) }
        var names: [String] = []
        while let record = readdir(directory) {
            let name = withUnsafePointer(to: &record.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= maxObjects + 2 else { throw VolumeError.capacity }
        }
        try storage.validate()
        return names
    }
    private static func seal<T: Encodable>(_ value: T, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: aad).combined!
    }
    private static func open<T: Decodable>(_ type: T.Type, data: Data, key: SymmetricKey, aad: Data) throws -> T {
        try JSONDecoder().decode(type, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad))
    }
    private static func validName(_ name: String) -> Bool {
        name != "." && name != ".." && name.utf8.count <= 64
            && name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    private static func validate(_ c: Catalogue, mode: String) throws {
        guard c.version == 1, UUID(uuidString: c.volume) != nil, c.mode == mode,
              c.entries.count <= maxFiles, c.nextID >= 2, c.nextID < UInt64.max,
              c.generation < UInt64.max else { throw VolumeError.invalid }
        var names = Set<String>(); var total = 0
        for (id, entry) in c.entries {
            let a = entry.attributes
            guard String(a.id) == id, a.id >= 2, a.id < c.nextID,
                  validName(a.name), names.insert(a.name).inserted,
                  a.size >= 0, a.size <= maxFileSize, a.mode <= 0o777,
                  a.modified <= UInt64(Int64.max), a.accessed <= UInt64(Int64.max), a.changed <= UInt64(Int64.max),
                  entry.verifier == nil || entry.verifier!.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
                  entry.leaves.count <= maxFileSize / shardSize else { throw VolumeError.invalid }
            total += a.size
            var pages = 0
            for (shard, leaf) in entry.leaves {
                guard let n = Int(shard), n >= 0, String(n) == shard,
                      n < (a.size + shardSize - 1) / shardSize,
                      UUID(uuidString: leaf.object) != nil, leaf.count > 0, leaf.count <= 256 else { throw VolumeError.invalid }
                pages += leaf.count
            }
            guard a.used == pages * (pageSize + 28) else { throw VolumeError.invalid }
        }
        guard total <= capacity else { throw VolumeError.capacity }
    }
    private func begin() throws {
        guard !poisoned else { throw PagingError.poisoned }
        guard !busy else { throw PagingError.busy }
        do {
            let data = try storage.read("catalogue.enc", limit: Self.catalogueLimit)
            guard Data(SHA256.hash(data: data)) == expectedDigest else { throw PagingError.invalid }
        } catch { poisoned = true; throw error }
        busy = true
    }
    private func entry(_ id: UInt64) throws -> Entry {
        guard let entry = catalogue.entries[String(id)] else { throw VolumeError.missing }
        return entry
    }
    private func reserve(_ count: Int) throws {
        guard count >= 0, objects <= Self.maxObjects - count else { throw VolumeError.capacity }
    }
    private func object(_ name: String, data: Data) throws {
        try reserve(1)
        objects += 1 // Count before I/O: an uncertain write may have materialised.
        try storage.write(name, data: data)
    }
    private func aad(_ kind: String, _ id: UInt64, _ position: Int, _ object: String) -> Data {
        Data("\(catalogue.volume)/\(kind)/\(id)/\(position)/\(object)".utf8)
    }
    private func leaf(_ entry: Entry, _ shard: Int) throws -> [String: String] {
        guard let reference = entry.leaves[String(shard)] else { return [:] }
        let raw = try storage.read("leaf-" + reference.object)
        let result = try Self.open([String: String].self, data: raw, key: key,
                                   aad: aad("leaf", entry.attributes.id, shard, reference.object))
        guard result.count == reference.count else { throw PagingError.invalid }
        for (block, object) in result {
            guard let n = Int(block), n >= 0, n < 256, String(n) == block,
                  (shard * 256 + n) * Self.pageSize < entry.attributes.size,
                  UUID(uuidString: object) != nil else { throw PagingError.invalid }
        }
        return result
    }
    private func page(_ entry: Entry, _ block: Int, _ leaf: [String: String]) async throws -> Data {
        guard let object = leaf[String(block % 256)] else { return Data(repeating: 0, count: Self.pageSize) }
        let raw: Data
        if let remote = remote, !mirror {
            do { raw = try await remote.get(key: "cloudswap-lab/\(object)/probe") }
            catch PagingError.missing { throw PagingError.unavailable }
        } else { raw = try storage.read("page-" + object, limit: Self.pageSize + 28) }
        guard raw.count == Self.pageSize + 28 else { throw PagingError.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: key,
                                     authenticating: aad("page", entry.attributes.id, block, object))
        guard plain.count == Self.pageSize else { throw PagingError.invalid }
        try storage.validate()
        return plain
    }
    private func savePage(_ id: UInt64, _ block: Int, _ bytes: Data) async throws -> String {
        let name = UUID().uuidString.lowercased()
        let payload = try AES.GCM.seal(bytes, using: key, authenticating: aad("page", id, block, name)).combined!
        if remote == nil || mirror { try object("page-" + name, data: payload) }
        else {
            // An encrypted local intent bounds/counts remote objects and retains
            // the unique key even if PUT succeeds but its response is lost.
            try object("intent-" + name, data: Self.seal(["object": name], key: key, aad: aad("intent", id, block, name)))
        }
        if let remote = remote { try await remote.put(key: "cloudswap-lab/\(name)/probe", data: payload) }
        return name
    }
    private func saveLeaf(_ entry: inout Entry, _ shard: Int, _ values: [String: String]) throws {
        if values.isEmpty { entry.leaves.removeValue(forKey: String(shard)); return }
        let name = UUID().uuidString.lowercased()
        try object("leaf-" + name, data: Self.seal(values, key: key, aad: aad("leaf", entry.attributes.id, shard, name)))
        entry.leaves[String(shard)] = LeafRef(object: name, count: values.count)
    }
    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000_000) }
    private func commit(_ next: Catalogue) throws {
        var next = next
        guard next.generation < UInt64.max - 1 else { throw VolumeError.capacity }
        next.generation += 1
        try Self.validate(next, mode: catalogue.mode)
        let data = try Self.seal(next, key: key, aad: Self.catalogueAAD)
        guard data.count <= Self.catalogueLimit else { throw VolumeError.capacity }
        try storage.write("catalogue.enc", data: data)
        catalogue = next; expectedDigest = Data(SHA256.hash(data: data))
    }
    private func commitEntry(_ entry: Entry, touchModified: Bool = true) throws -> Attributes {
        var entry = entry
        entry.attributes.used = entry.leaves.values.reduce(0) { $0 + $1.count } * (Self.pageSize + 28)
        entry.attributes.changed = Self.now()
        if touchModified { entry.attributes.modified = entry.attributes.changed }
        var next = catalogue; next.entries[String(entry.attributes.id)] = entry
        try commit(next)
        return entry.attributes
    }
    private func checkSize(_ id: UInt64, _ size: Int) throws {
        guard size >= 0, size <= Self.maxFileSize else { throw VolumeError.invalid }
        let other = catalogue.entries.values.filter { $0.attributes.id != id }.reduce(0) { $0 + $1.attributes.size }
        guard size <= Self.capacity - other else { throw VolumeError.capacity }
    }
    public func list() throws -> [Attributes] {
        try begin(); defer { busy = false }
        return catalogue.entries.values.map(\.attributes).sorted { $0.id < $1.id }
    }
    public func attributes(_ id: UInt64) throws -> Attributes {
        try begin(); defer { busy = false }
        return try entry(id).attributes
    }
    public func create(name: String, size: Int = 0, mode: UInt32 = 0o600, uid: UInt32 = 0, gid: UInt32 = 0, verifier: String? = nil, modified: UInt64? = nil, accessed: UInt64? = nil) throws -> Attributes {
        guard Self.validName(name), mode <= 0o777,
              (modified == nil || modified! <= UInt64(Int64.max)), (accessed == nil || accessed! <= UInt64(Int64.max)),
              verifier == nil || verifier!.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil else { throw VolumeError.invalid }
        try begin(); defer { busy = false }
        if let existing = catalogue.entries.values.first(where: { $0.attributes.name == name }) {
            if let verifier = verifier, existing.verifier == verifier { return existing.attributes }
            throw VolumeError.exists
        }
        guard catalogue.entries.count < Self.maxFiles, catalogue.nextID < UInt64.max - 1 else { throw VolumeError.capacity }
        try checkSize(catalogue.nextID, size)
        let time = Self.now()
        let a = Attributes(id: catalogue.nextID, name: name, size: size, mode: mode, uid: uid, gid: gid, modified: modified ?? time, accessed: accessed ?? time, changed: time, used: 0)
        var next = catalogue; next.nextID += 1; next.entries[String(a.id)] = Entry(attributes: a, leaves: [:], verifier: verifier)
        do { try commit(next) } catch { poisoned = true; throw error }
        return a
    }
    public func read(_ id: UInt64, offset: Int, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, count <= Self.maxRequest else { throw VolumeError.invalid }
        try begin(); defer { busy = false }
        let e = try entry(id)
        if offset >= e.attributes.size { return Data() }
        let end = offset + min(count, e.attributes.size - offset)
        var result = Data(); var position = offset
        do {
            while position < end {
                let block = position / Self.pageSize
                let bytes = try await page(e, block, leaf(e, block / 256))
                let within = position % Self.pageSize
                let n = min(Self.pageSize - within, end - position)
                result.append(bytes.subdata(in: within..<(within + n))); position += n
            }
        } catch { poisoned = true; throw error }
        return result
    }
    public func write(_ id: UInt64, offset: Int, data: Data) async throws -> Attributes {
        guard offset >= 0, offset <= Self.maxFileSize, data.count <= Self.maxRequest,
              data.count <= Self.maxFileSize - offset else { throw VolumeError.invalid }
        try begin(); defer { busy = false }
        var e = try entry(id)
        if data.isEmpty { return e.attributes }
        try checkSize(id, max(e.attributes.size, offset + data.count))
        try reserve(7) // At most five pages and two new leaves for one request.
        do {
            var leaves: [Int: [String: String]] = [:]
            var consumed = 0
            while consumed < data.count {
                let position = offset + consumed, block = position / Self.pageSize, shard = block / 256
                let within = position % Self.pageSize, n = min(Self.pageSize - within, data.count - consumed)
                if leaves[shard] == nil { leaves[shard] = try leaf(e, shard) }
                var bytes = within == 0 && n == Self.pageSize ? Data(repeating: 0, count: Self.pageSize)
                    : try await page(e, block, leaves[shard]!)
                let source = data.startIndex + consumed
                bytes.replaceSubrange(within..<(within + n), with: data[source..<(source + n)])
                leaves[shard]![String(block % 256)] = try await savePage(id, block, bytes)
                consumed += n
            }
            for (shard, values) in leaves { try saveLeaf(&e, shard, values) }
            e.attributes.size = max(e.attributes.size, offset + data.count)
            return try commitEntry(e)
        } catch { poisoned = true; throw error }
    }
    public func resize(_ id: UInt64, size: Int, mode: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil, modified: UInt64? = nil, accessed: UInt64? = nil) async throws -> Attributes {
        guard (mode == nil || mode! <= 0o777),
              (modified == nil || modified! <= UInt64(Int64.max)),
              (accessed == nil || accessed! <= UInt64(Int64.max)) else { throw VolumeError.invalid }
        try begin(); defer { busy = false }
        var e = try entry(id)
        try checkSize(id, size)
        let sizeChanged = size != e.attributes.size
        do {
            if size < e.attributes.size {
                let shard = size / Self.shardSize
                for name in Array(e.leaves.keys) where Int(name)! > shard || (Int(name)! == shard && size % Self.shardSize == 0) {
                    e.leaves.removeValue(forKey: name)
                }
                if size % Self.shardSize != 0, e.leaves[String(shard)] != nil {
                    try reserve(2)
                    var values = try leaf(e, shard)
                    let block = size / Self.pageSize
                    let within = size % Self.pageSize
                    for n in Array(values.keys) where shard * 256 + Int(n)! > block || (shard * 256 + Int(n)! == block && within == 0) {
                        values.removeValue(forKey: n)
                    }
                    if within != 0, values[String(block % 256)] != nil {
                        var bytes = try await page(e, block, values)
                        bytes.replaceSubrange(within..<Self.pageSize, with: repeatElement(UInt8(0), count: Self.pageSize - within))
                        values[String(block % 256)] = try await savePage(id, block, bytes)
                    }
                    try saveLeaf(&e, shard, values)
                }
            }
            e.attributes.size = size
            if let mode = mode { e.attributes.mode = mode }
            if let uid = uid { e.attributes.uid = uid }
            if let gid = gid { e.attributes.gid = gid }
            if let modified = modified { e.attributes.modified = modified }
            if let accessed = accessed { e.attributes.accessed = accessed }
            return try commitEntry(e, touchModified: sizeChanged && modified == nil)
        } catch { poisoned = true; throw error }
    }
    public func remove(_ id: UInt64) throws {
        try begin(); defer { busy = false }; _ = try entry(id)
        var next = catalogue; next.entries.removeValue(forKey: String(id))
        do { try commit(next) } catch { poisoned = true; throw error }
    }
    public func rename(_ id: UInt64, name: String) throws -> Attributes {
        guard Self.validName(name) else { throw VolumeError.invalid }
        try begin(); defer { busy = false }; var e = try entry(id)
        if let other = catalogue.entries.values.first(where: { $0.attributes.name == name }), other.attributes.id != id {
            // Atomic replacement: the target handle becomes stale after commit.
            var next = catalogue; next.entries.removeValue(forKey: String(other.attributes.id))
            e.attributes.name = name; e.attributes.changed = Self.now(); next.entries[String(id)] = e
            do { try commit(next); return e.attributes } catch { poisoned = true; throw error }
        }
        e.attributes.name = name
        do { return try commitEntry(e, touchModified: false) } catch { poisoned = true; throw error }
    }
    public func objectCount() throws -> Int { try begin(); defer { busy = false }; return objects }
    public func checkpoint() throws {
        try begin(); defer { busy = false }
        do {
            for entry in catalogue.entries.values {
                for shard in entry.leaves.keys { _ = try leaf(entry, Int(shard)!) }
            }
        } catch { poisoned = true; throw error }
    }
}
