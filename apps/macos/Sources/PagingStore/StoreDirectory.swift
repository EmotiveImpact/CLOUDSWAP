import Foundation
import Darwin

/// Pins all I/O to the opened directory, even if its pathname is replaced.
final class StoreDirectory {
    let fd: Int32
    let path: String
    init(_ url: URL) throws {
        path = url.path
        fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PagingError.unavailable }
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        var opened = stat(), current = stat()
        guard fstat(fd, &opened) == 0, lstat(path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else { throw PagingError.unavailable }
    }
    func lock() throws -> FileLock {
        try validate()
        let handle = openat(fd, "writer.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw PagingError.busy }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(handle); throw PagingError.busy }
        return FileLock(handle)
    }
    func read(_ name: String, limit: Int = 65536) throws -> Data {
        try validate()
        let handle = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard handle >= 0 else { throw PagingError.unavailable }
        defer { Darwin.close(handle) }
        var info = stat()
        guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw PagingError.invalid }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PagingError.unavailable }
            if count == 0 { break }
            guard result.count + count <= limit else { throw PagingError.invalid }
            result.append(contentsOf: buffer.prefix(count))
        }
        try validate()
        return result
    }
    func write(_ name: String, data: Data) throws {
        try validate()
        let temporary = ".pending-" + UUID().uuidString
        let handle = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw PagingError.unavailable }
        defer { Darwin.close(handle); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(handle, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PagingError.unavailable }
                offset += count
            }
        }
        guard fsync(handle) == 0 else { throw PagingError.unavailable }
        try validate()
        guard renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw PagingError.unavailable }
        try validate()
    }
    func remove(_ name: String) { _ = unlinkat(fd, name, 0) }
}
