import CryptoKit
import Foundation

/// Files that hold a secret (the notify token, the header file made from it, the permission key). Each is private from the
/// first byte it exists: it is created with mode 0600 and `O_EXCL`, so no other user can open it in between the creation
/// and a later `chmod`, and it takes the place of the old file in a single rename.
enum SecretFiles {
    /// Creates `url` for writing, mode 0600, failing if anything is there already (a symbolic link included). The mode is
    /// given to `open` itself, and the umask can only take bits away from it.
    static func createPrivate(at url: URL) -> Int32? {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        // A umask that took owner bits away would leave a file this process can't reopen; it is never made wider.
        fchmod(fd, 0o600)
        return fd
    }

    /// Writes `text` to `url`: private from creation, flushed to disk, then renamed over the old file. False on any failure,
    /// with nothing left behind.
    @discardableResult
    static func write(_ text: String, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        makeDirectoryPrivate(directory)
        let scratch = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard let fd = createPrivate(at: scratch) else { return false }
        var written = true
        Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { written = false; break }
                offset += count
            }
        }
        written = written && fsync(fd) == 0
        close(fd)
        guard written, rename(scratch.path, url.path) == 0 else {
            unlink(scratch.path)
            return false
        }
        return true
    }

    /// Makes `directory` (the one that holds the secrets, nothing above it) 0700: created that way, or tightened when it
    /// is found wider.
    static func makeDirectoryPrivate(_ directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var info = stat()
        if stat(directory.path, &info) == 0, info.st_mode & 0o077 != 0 {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// 32 random bytes as 64 lowercase hex characters.
    static func randomHex() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }
}
