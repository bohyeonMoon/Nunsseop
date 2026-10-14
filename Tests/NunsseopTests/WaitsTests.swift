import Foundation
import Testing

/// A wait that counts its cap in wall-clock time (`Date.now < deadline`) gives up on a busy machine without the event having had its turn: the
/// main actor is kept from running for minutes at a time, and the wait resumes after its cap with nothing yet done. `eventually` charges a late
/// wake-up for a second at most (see there), so the tests wait with it.
struct WaitsTests {
    @Test func noTestCountsTheCapOfItsOwnWaitInWallClockTimeButEventually() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            if ["PermissionTestSupport.swift", "WaitsTests.swift"].contains(file.lastPathComponent) { continue }
            for (number, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("< deadline") || line.contains("<deadline") {
                found.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(found.isEmpty, "\(found)")
    }

    /// A script that waits for the test has no clock of its own: the test it waits for can be kept from answering for two minutes, and a script
    /// that stopped waiting before it did went on without the answer. It ends when the process of the test is gone.
    @Test func aNodeScriptsWaitsHaveNoCapOfTheirOwn() {
        #expect(!NodeScript.prelude.contains("Date.now") && NodeScript.prelude.contains("process.ppid"))
    }
}
