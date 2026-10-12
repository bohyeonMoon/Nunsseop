import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct DownloadProgressTests {
    @Test func bytesAcrossDownloadsRoundedDown() {
        #expect(DownloadWatcher.status(of: []) == nil)
        #expect(DownloadWatcher.status(of: [(completed: 1, total: 4)]) == .init(percent: 25))
        // Weighted by size, not averaged per file: 10 + 0 of 100 + 300 bytes.
        #expect(DownloadWatcher.status(of: [(completed: 10, total: 100), (completed: 0, total: 300)]) == .init(percent: 2))
        // 99.9% is not done yet.
        #expect(DownloadWatcher.status(of: [(completed: 999, total: 1000)]) == .init(percent: 99))
        #expect(DownloadWatcher.status(of: [(completed: 1000, total: 1000)]) == .init(percent: 100))
    }

    @Test func downloadsOfUnknownSizeShowButDontCount() {
        // Chrome reports -1 until the server says how big the file is.
        #expect(DownloadWatcher.status(of: [(completed: 0, total: -1)]) == .init(percent: nil))
        #expect(DownloadWatcher.status(of: [(completed: 5, total: -1), (completed: 50, total: 100)]) == .init(percent: 50))
        // Reports past the end, or negative, stay within 0...100.
        #expect(DownloadWatcher.status(of: [(completed: 150, total: 100)]) == .init(percent: 100))
        #expect(DownloadWatcher.status(of: [(completed: -3, total: 100)]) == .init(percent: 0))
        // Sizes come from any process that publishes; huge ones mustn't overflow.
        #expect(DownloadWatcher.status(of: [(completed: .max, total: .max), (completed: 0, total: .max)]) == .init(percent: 50))
    }

    /// The same path a browser's report takes: published for a file in the folder, then withdrawn when it's done.
    @Test func followsPublishedDownloadsInTheFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadWatcher()
        watcher.start(in: folder)

        let copy = Self.publish(folder.appendingPathComponent("copied.zip"), kind: .copying, of: 100)
        let download = Self.publish(folder.appendingPathComponent("big.zip.crdownload"), kind: .downloading, of: 200)
        download.completedUnitCount = 50
        #expect(await Self.wait { watcher.status == .init(percent: 25) })

        download.completedUnitCount = 200
        #expect(await Self.wait { watcher.status == .init(percent: 100) })
        download.unpublish()
        copy.unpublish()
        #expect(await Self.wait { watcher.status == nil })
    }

    private static func publish(_ file: URL, kind: Progress.FileOperationKind, of total: Int64) -> Progress {
        let progress = Progress(totalUnitCount: total)
        progress.kind = .file
        progress.fileOperationKind = kind
        progress.fileURL = file
        progress.publish()
        return progress
    }

    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(eventDeadline)
        while !condition() && Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
