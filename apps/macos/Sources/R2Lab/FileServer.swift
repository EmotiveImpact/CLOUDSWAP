import Foundation
import CryptoKit
import Darwin
import PagingStore

private struct FileRequest: Decodable {
    let id: Int
    let op: String
    let offset: Int?
    let count: Int?
    let data: String?
}
private struct FileResponse: Encodable {
    var id: Int
    var ok: Bool
    var error: String?
    var data: String?
    var count: Int?
    var capacity: Int?
}
private final class FrameReader {
    var pending = Data()
    func next() throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                guard newline <= 100_000 else { throw PagingError.invalid }
                let frame = Data(pending.prefix(upTo: newline))
                pending = Data(pending.suffix(from: pending.index(after: newline)))
                return frame
            }
            guard pending.count <= 100_000 else { throw PagingError.invalid }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PagingError.unavailable }
            if count == 0 {
                guard pending.isEmpty else { throw PagingError.invalid }
                return nil
            }
            pending.append(contentsOf: buffer.prefix(count))
        }
    }
}

extension R2Lab {
    private static func send(_ response: FileResponse) throws {
        var bytes = try JSONEncoder().encode(response); bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
    static func fileServer() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard args.count == 3, args[0] == "--file-server",
                  ["local-create", "local-open", "remote-create", "remote-open", "mirror-create", "mirror-open"].contains(args[1]),
                  let hex = ProcessInfo.processInfo.environment["CLOUDSWAP_FILE_KEY_HEX"],
                  hex.utf8.count == 64,
                  hex.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { throw PagingError.invalid }
            var rawKey = Data()
            for index in stride(from: 0, to: 64, by: 2) {
                let a = hex.index(hex.startIndex, offsetBy: index), b = hex.index(a, offsetBy: 2)
                rawKey.append(UInt8(hex[a..<b], radix: 16)!)
            }
            let key = SymmetricKey(data: rawKey)
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            let mode = args[1]
            let create = mode.hasSuffix("-create")
            let backend: FilePageBackend
            if mode.hasPrefix("local-") {
                if create {
                    // Atomic create rejects existing directories. PagingStore opens this empty directory.
                    guard mkdir(root.path, 0o700) == 0 else { throw PagingError.unavailable }
                } else {
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("index.enc").path) else { throw PagingError.missing }
                }
                backend = try PagingStore(directory: root, key: key)
            } else {
                let client = try R2Client()
                backend = try RemotePager(directory: root, key: key, backend: client, create: create, mirror: mode.hasPrefix("mirror-"))
            }
            let file = VirtualPageFile(backend: backend)
            try send(FileResponse(id: 0, ok: true, capacity: VirtualPageFile.capacity))
            let reader = FrameReader()
            while let frame = try reader.next() {
                var id = 0
                do {
                    let request = try JSONDecoder().decode(FileRequest.self, from: frame); id = request.id
                    guard id > 0 else { throw PagingError.invalid }
                    switch request.op {
                    case "read":
                        guard let offset = request.offset, let count = request.count else { throw PagingError.invalid }
                        let data = try await file.read(offset: offset, count: count)
                        try send(FileResponse(id: id, ok: true, data: data.base64EncodedString(), count: data.count))
                    case "write":
                        guard let offset = request.offset, let text = request.data, let data = Data(base64Encoded: text) else { throw PagingError.invalid }
                        let count = try await file.write(offset: offset, data: data)
                        try send(FileResponse(id: id, ok: true, count: count))
                    case "flush", "close":
                        try await file.flush()
                        try send(FileResponse(id: id, ok: true))
                        if request.op == "close" { return }
                    default:
                        try send(FileResponse(id: id, ok: false, error: "ENOTSUP"))
                    }
                } catch {
                    let label: String
                    switch error {
                    case PagingError.invalid, is DecodingError: label = "EINVAL"
                    case PagingError.busy: label = "EBUSY"
                    default: label = "EIO"
                    }
                    try send(FileResponse(id: id, ok: false, error: label))
                }
            }
        } catch {
            // Fixed text only: do not disclose environment keys, request bodies or URLs.
            try? FileHandle.standardError.write(contentsOf: Data("File server unavailable: check mode, directory, key and backend configuration.\n".utf8))
            exit(1)
        }
    }
}
