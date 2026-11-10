import Foundation

/// Missing means never written, not a lost committed object. Successful writes
/// must finish the backend's commit before returning. No write-back cache here.
public protocol FilePageBackend {
    func read(block: Int) async throws -> Data
    func write(block: Int, data: Data) async throws
    func checkpoint() async throws
}
extension PagingStore: FilePageBackend {}
extension RemotePager: FilePageBackend {}

/// One fixed-size file; range writes are page commits, not multi-page transactions.
public actor VirtualPageFile {
    public static let capacity = PagingStore.blockSize * PagingStore.maxBlocks
    public static let maxRequest = 65536
    private let backend: FilePageBackend
    private var busy = false
    private var poisoned = false
    public init(backend: FilePageBackend) { self.backend = backend }
    private func begin() throws {
        guard !poisoned else { throw PagingError.poisoned }
        guard !busy else { throw PagingError.busy }
        busy = true
    }
    private func page(_ block: Int) async throws -> Data {
        do {
            let data = try await backend.read(block: block)
            guard data.count == PagingStore.blockSize else { throw PagingError.invalid }
            return data
        } catch PagingError.missing {
            return Data(repeating: 0, count: PagingStore.blockSize)
        }
    }
    public func read(offset: Int, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, count <= Self.maxRequest else { throw PagingError.invalid }
        try begin(); defer { busy = false }
        guard offset < Self.capacity else { return Data() }
        let end = offset + min(count, Self.capacity - offset)
        var position = offset
        var result = Data()
        while position < end {
            let block = position / PagingStore.blockSize
            let within = position % PagingStore.blockSize
            let length = min(PagingStore.blockSize - within, end - position)
            let bytes = try await page(block)
            result.append(bytes.subdata(in: within..<(within + length)))
            position += length
        }
        return result
    }
    public func write(offset: Int, data: Data) async throws -> Int {
        guard offset >= 0, offset <= Self.capacity, data.count <= Self.maxRequest,
              data.count <= Self.capacity - offset else { throw PagingError.invalid }
        try begin(); defer { busy = false }
        var consumed = 0
        do {
            while consumed < data.count {
                let position = offset + consumed
                let block = position / PagingStore.blockSize
                let within = position % PagingStore.blockSize
                let length = min(PagingStore.blockSize - within, data.count - consumed)
                var bytes = within == 0 && length == PagingStore.blockSize
                    ? Data(repeating: 0, count: PagingStore.blockSize) : try await page(block)
                bytes.replaceSubrange(within..<(within + length), with: data[consumed..<(consumed + length)])
                try await backend.write(block: block, data: bytes)
                consumed += length
            }
            return consumed
        } catch {
            // Earlier pages may have committed; never retry this range implicitly.
            poisoned = true
            throw error
        }
    }
    public func flush() async throws {
        try begin(); defer { busy = false }
        do { try await backend.checkpoint() }
        catch { poisoned = true; throw error }
    }
}
