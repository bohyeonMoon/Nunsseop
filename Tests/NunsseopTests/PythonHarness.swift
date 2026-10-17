import Foundation
import Testing
@testable import Nunsseop

/// python3, when this machine has it, for the tests that run the Hermes plugin for real. A test that needs it is skipped where it is
/// missing; the text of the plugin is pinned by a golden file either way.
enum PythonTool {
    static let url: URL? = (ProcessInfo.processInfo.environment["NUNSSEOP_TEST_PYTHON"].map { [$0] } ?? [])
        .appending(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    static var available: Bool { url != nil }
    static let reason: Comment = "python3 is not installed, so the Hermes plugin can't be run here"
}

/// A scratch folder with the files a Python script imports, and the script run in it, in the environment of `HookProcess`.
final class PythonScript {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-python-\(UUID().uuidString.prefix(8))")
    let process: HookProcess

    /// - files: written beside the script, by path (a folder in the name makes a package).
    init(files: [String: String], main: String, home: URL, environment: [String: String] = [:]) throws {
        for (name, text) in files.merging(["main.py": main]) { $1 } {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        guard let python = PythonTool.url else { throw POSIXError(.ENOENT) }
        process = try HookProcess(command: "cd '\(folder.path)' && exec '\(python.path)' -B main.py", home: home, stdin: Data(), environment: environment)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The lines the script printed, as JSON, once it has ended.
    func finish() async -> (lines: [[String: Any]], status: Int32)? {
        guard let result = await process.finish() else { return nil }
        let lines = result.stdout.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        return (lines, result.status)
    }
}

private extension Array {
    func appending(_ other: [Element]) -> [Element] { self + other }
}
