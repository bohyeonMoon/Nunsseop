import Foundation
import Testing
@testable import Nunsseop

/// node, when this machine has it, for the tests that run the pi extension and the OpenCode plugin for real. A test that needs it is
/// skipped (`.enabled(if: NodeTool.available, ...)`) where it is missing; the text of both is checked by golden files either way.
enum NodeTool {
    /// `NUNSSEOP_TEST_NODE=$(which bun)` runs the same scripts under Bun, which is what omp, omo and OpenCode run on.
    static let url: URL? = (ProcessInfo.processInfo.environment["NUNSSEOP_TEST_NODE"].map { [$0] } ?? [])
        .appending(contentsOf: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"])
        .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    static var available: Bool { url != nil }
    static let reason: Comment = "node is not installed, so the extension and the plugin can't be run here"
}

/// A scratch folder with the files a node script imports, and the script run in it. Its environment is HOME and PATH, as a tool's would
/// be under `HookProcess`, plus what a test adds.
final class NodeScript {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-node-\(UUID().uuidString.prefix(8))")
    let process: HookProcess

    /// - files: written beside the script, by name.
    /// - main: the script, an ES module.
    init(files: [String: String], main: String, home: URL, environment: [String: String] = [:]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files.merging(["main.mjs": main]) { $1 } {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let node = try unwrap(NodeTool.url)
        process = try HookProcess(command: "cd '\(folder.path)' && exec '\(node.path)' main.mjs", home: home, stdin: Data(),
                                  environment: environment)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The lines the script printed, as JSON, once it has ended; nil if it is still running after the cap.
    func finish() async -> (lines: [[String: Any]], status: Int32)? {
        guard let result = await process.finish() else { return nil }
        let lines = result.stdout.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        return (lines, result.status)
    }

    /// Lets a script that waits at `gate(name)` go on. The test calls it once what the script is to wait for has happened, so the
    /// script's order does not rest on how long anything takes.
    func open(_ name: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }

    /// Helpers every script starts with: `out(value)` prints a JSON line, `sleep(ms)`, `until(predicate)` and `gate(name)`, which wait for an
    /// event as long as the test does: the main actor can keep the test from answering for two minutes on a busy machine, and a script that
    /// stopped waiting before that went on without the answer. A script that is waiting has no cap of its own, since the test's process is what
    /// it waits on: it stops when that process is gone (its parent, which a script started by a test that crashed has no longer).
    static let prelude = """
        import { existsSync } from "node:fs"
        const out = (value) => console.log(JSON.stringify(value))
        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
        const until = async (predicate) => { const parent = process.ppid; while (!predicate() && process.ppid === parent) await sleep(20) }
        const gate = (name) => until(() => existsSync(name))

        """
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw POSIXError(.ENOENT) }
    return value
}

private extension Array {
    func appending(contentsOf other: [Element]) -> [Element] { self + other }
}
