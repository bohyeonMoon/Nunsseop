import Foundation
import Testing
@testable import Nunsseop

/// The notify token, its header file and the permission key are private from the first byte they exist.
struct SecretFilesTests {
    private let fileManager = FileManager.default

    private func mode(_ url: URL) -> Int? { (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil }

    private func scratch() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("nunsseop-secret-\(UUID().uuidString.prefix(8))")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Under the umask that makes ordinary files readable by everyone, the file as created is still 0600: its mode is given to
    /// `open` itself, not set by a `chmod` after it.
    @Test func aSecretFileIsCreatedWithMode0600UnderAUmaskThatWouldOpenItUp() throws {
        let dir = try scratch()
        defer { try? fileManager.removeItem(at: dir) }
        let previous = umask(0o022)
        defer { umask(previous) }
        let url = dir.appendingPathComponent("secret")
        let fd = try #require(SecretFiles.createPrivate(at: url))
        defer { close(fd) }
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "mode \(String(info.st_mode & 0o777, radix: 8)) as created")
        // The control: an ordinary file made under the same umask is open to everyone.
        let ordinary = dir.appendingPathComponent("ordinary")
        #expect(fileManager.createFile(atPath: ordinary.path, contents: Data()))
        #expect(mode(ordinary) == 0o644)
    }

    @Test func creatingNeverReplacesOrFollowsWhatIsThere() throws {
        let dir = try scratch()
        defer { try? fileManager.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: existing)
        #expect(SecretFiles.createPrivate(at: existing) == nil)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        // A link planted where the scratch file goes is not written through.
        let target = dir.appendingPathComponent("target"), link = dir.appendingPathComponent("link")
        try Data("untouched".utf8).write(to: target)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(SecretFiles.createPrivate(at: link) == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test func writingReplacesTheOldFileInOneStepPrivatelyAndLeavesNothingBehind() throws {
        let dir = try scratch()
        defer { try? fileManager.removeItem(at: dir) }
        let url = dir.appendingPathComponent("secret")
        try Data("old".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(SecretFiles.write("new", to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        #expect(mode(url) == 0o600)
        #expect(try fileManager.contentsOfDirectory(atPath: dir.path) == ["secret"])
    }

    /// Another user polling the folder while secrets are written never finds one that is open to anyone but its owner.
    @Test func noWrittenSecretIsEverObservableWithAWiderMode() throws {
        let dir = try scratch()
        defer { try? fileManager.removeItem(at: dir) }
        final class Watch: @unchecked Sendable {
            let lock = NSLock()
            var stop = false, seen = 0
            var wider: [String] = []
        }
        let watch = Watch()
        let watcher = Thread {
            while !watch.lock.withLock({ watch.stop }) {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    var info = stat()
                    guard stat(dir.appendingPathComponent(name).path, &info) == 0 else { continue }
                    watch.lock.withLock {
                        watch.seen += 1
                        if info.st_mode & 0o077 != 0 { watch.wider.append("\(name) \(String(info.st_mode & 0o777, radix: 8))") }
                    }
                }
            }
        }
        let previous = umask(0o022)
        defer { umask(previous) }
        watcher.start()
        for index in 0..<300 {
            #expect(SecretFiles.write(String(repeating: "x", count: 64) + "\(index)", to: dir.appendingPathComponent("secret-\(index % 3)")))
        }
        watch.lock.withLock { watch.stop = true }
        let (seen, wider) = watch.lock.withLock { (watch.seen, watch.wider) }
        #expect(wider.isEmpty, "\(wider.prefix(3))")
        #expect(seen > 0, "the watcher never saw a file")
    }

    @Test func theFolderIsMadePrivateWhenCreatedOrFoundWiderAndNothingAboveItIsTouched() throws {
        try withTempHome { home in
            let support = home.appendingPathComponent("Library/Application Support")
            let folder = support.appendingPathComponent("Nunsseop")
            // Created by Nunsseop: 0700.
            _ = NotifyServer()
            #expect(mode(folder) == 0o700)
            // Found wider (an earlier version made it 0755): tightened, and the folders above are left as they were.
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            _ = NotifyServer()
            #expect(mode(folder) == 0o700)
            #expect(mode(support) == 0o755)
            // Already narrower: not made wider.
            try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            SecretFiles.makeDirectoryPrivate(folder)
            #expect(mode(folder) == 0o500)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    @Test func theTokenItsHeaderFileAndThePermissionKeyAreAllPrivateAndDifferent() throws {
        try withTempHome { home in
            let folder = home.appendingPathComponent("Library/Application Support/Nunsseop")
            let server = NotifyServer()
            for name in ["notify-token", "notify-auth", "permission-key"] {
                #expect(mode(folder.appendingPathComponent(name)) == 0o600, "\(name)")
            }
            #expect(server.permissionKey.count == 64 && server.permissionKey.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(server.permissionKey != server.token)
            #expect(try String(contentsOf: NotifyServer.permissionKeyURL, encoding: .utf8) == server.permissionKey)
            // The header file carries the token and nothing of the key.
            let header = try String(contentsOf: NotifyServer.authHeaderURL, encoding: .utf8)
            #expect(header == "Authorization: Bearer \(server.token)\n")
            // The next launch reads the same key.
            #expect(NotifyServer().permissionKey == server.permissionKey)
        }
    }

    @Test func aShortOrLooselyHeldPermissionKeyIsReplacedOrTightened() throws {
        try withTempHome { home in
            let folder = home.appendingPathComponent("Library/Application Support/Nunsseop")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("permission-key")
            try Data("short".utf8).write(to: file)
            let replaced = NotifyServer().permissionKey
            #expect(replaced != "short" && replaced.count == 64)
            let existing = String(repeating: "c", count: 40)
            try Data((existing + "\n").utf8).write(to: file)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(NotifyServer().permissionKey == existing)
            #expect(mode(file) == 0o600)
        }
    }
}
