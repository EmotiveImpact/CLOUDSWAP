import Foundation
import CryptoKit
import Darwin
import PagingStore

private struct VolumeRequest: Decodable {
    let id: Int
    let op: String
    let file: UInt64?
    let name: String?
    let offset: Int?
    let count: Int?
    let data: String?
    let size: Int?
    let mode: UInt32?
    let uid: UInt32?
    let gid: UInt32?
    let modified: UInt64?
    let accessed: UInt64?
    let verifier: String?
    let unchecked: Bool?
}
private struct VolumeResponse: Encodable {
    var id: Int
    var ok: Bool
    var error: String?
    var data: String?
    var count: Int?
    var eof: Bool?
    var attributes: SparseVolume.Attributes?
    var files: [SparseVolume.Attributes]?
    var kind: String?
    var capacity: Int?
    var maxFileSize: Int?
    var objectCount: Int?
    var maxObjects: Int?
}
extension R2Lab {
    private static func sendVolume(_ response: VolumeResponse) throws {
        var bytes = try JSONEncoder().encode(response); bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
    static func volumeServer() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard args.count == 3, args[0] == "--volume-server",
                  ["local-create", "local-open", "remote-create", "remote-open", "mirror-create", "mirror-open"].contains(args[1]),
                  let hex = ProcessInfo.processInfo.environment["CLOUDSWAP_FILE_KEY_HEX"],
                  hex.utf8.count == 64, hex.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { throw PagingError.invalid }
            var rawKey = Data()
            for i in stride(from: 0, to: 64, by: 2) {
                let a = hex.index(hex.startIndex, offsetBy: i), b = hex.index(a, offsetBy: 2)
                rawKey.append(UInt8(hex[a..<b], radix: 16)!)
            }
            let mode = args[1]
            let remote: ObjectBackend? = mode.hasPrefix("local-") ? nil : try R2Client()
            let volume = try SparseVolume(directory: URL(fileURLWithPath: args[2], isDirectory: true),
                key: SymmetricKey(data: rawKey), create: mode.hasSuffix("-create"), remote: remote, mirror: mode.hasPrefix("mirror-"))
            try sendVolume(VolumeResponse(id: 0, ok: true, kind: "sparse-volume-v1", capacity: SparseVolume.capacity,
                                          maxFileSize: SparseVolume.maxFileSize, maxObjects: SparseVolume.maxObjects))
            let reader = FrameReader()
            while let frame = try reader.next() {
                var id = 0
                do {
                    let r = try JSONDecoder().decode(VolumeRequest.self, from: frame); id = r.id
                    guard id > 0 else { throw VolumeError.invalid }
                    var reply = VolumeResponse(id: id, ok: true)
                    switch r.op {
                    case "list":
                        reply.files = try await volume.list()
                        reply.objectCount = try await volume.objectCount()
                    case "stat":
                        guard let file = r.file else { throw VolumeError.invalid }
                        reply.attributes = try await volume.attributes(file)
                    case "create":
                        guard let name = r.name else { throw VolumeError.invalid }
                        do {
                            reply.attributes = try await volume.create(name: name, size: r.size ?? 0,
                                mode: r.mode ?? 0o600, uid: r.uid ?? getuid(), gid: r.gid ?? getgid(), verifier: r.verifier, modified: r.modified, accessed: r.accessed)
                        } catch VolumeError.exists {
                            guard r.unchecked == true, r.verifier == nil,
                                  let file = try await volume.list().first(where: { $0.name == name }) else { throw VolumeError.exists }
                            reply.attributes = try await volume.resize(file.id, size: r.size ?? file.size, mode: r.mode,
                                uid: r.uid, gid: r.gid, modified: r.modified, accessed: r.accessed)
                        }
                    case "setattr":
                        guard let file = r.file else { throw VolumeError.invalid }
                        let current = try await volume.attributes(file)
                        reply.attributes = try await volume.resize(file, size: r.size ?? current.size, mode: r.mode,
                            uid: r.uid, gid: r.gid, modified: r.modified, accessed: r.accessed)
                    case "read":
                        guard let file = r.file, let offset = r.offset, let count = r.count else { throw VolumeError.invalid }
                        let bytes = try await volume.read(file, offset: offset, count: count)
                        let a = try await volume.attributes(file)
                        reply.data = bytes.base64EncodedString(); reply.count = bytes.count
                        reply.eof = offset >= a.size || bytes.count >= a.size - offset
                    case "write":
                        guard let file = r.file, let offset = r.offset, let text = r.data,
                              let bytes = Data(base64Encoded: text) else { throw VolumeError.invalid }
                        reply.attributes = try await volume.write(file, offset: offset, data: bytes)
                        reply.count = bytes.count
                    case "rename":
                        guard let file = r.file, let name = r.name else { throw VolumeError.invalid }
                        reply.attributes = try await volume.rename(file, name: name)
                    case "remove":
                        guard let file = r.file else { throw VolumeError.invalid }
                        try await volume.remove(file)
                    case "flush", "close":
                        if let file = r.file { _ = try await volume.attributes(file) }
                        try await volume.checkpoint()
                    default: reply.ok = false; reply.error = "ENOTSUP"
                    }
                    try sendVolume(reply)
                    if r.op == "close" { return }
                } catch {
                    let label: String
                    switch error {
                    case VolumeError.invalid, PagingError.invalid, is DecodingError: label = "EINVAL"
                    case VolumeError.missing: label = "ENOENT"
                    case VolumeError.exists: label = "EEXIST"
                    case VolumeError.capacity: label = "ENOSPC"
                    case PagingError.busy: label = "EBUSY"
                    default: label = "EIO"
                    }
                    try sendVolume(VolumeResponse(id: id, ok: false, error: label))
                }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Sparse volume unavailable: check mode, directory, key and configuration.\n".utf8))
            exit(1)
        }
    }
}
