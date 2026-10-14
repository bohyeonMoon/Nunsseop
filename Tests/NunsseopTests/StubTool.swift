import Foundation
import Testing

/// Stand-ins for programs (`curl`, a terminal's command-line tool) that tests put in a scratch folder for the code under test to run.
///
/// Running a file that was written a moment ago costs more than it seems. macOS sends every executable it has not seen to `syspolicyd` for a
/// Gatekeeper scan (`GK performScan` in its log, one per file: about 190 in a run of this suite, none when nothing new is run), which reads the
/// file by its path some time after the program has started, while the test is deleting its scratch folder. `syspolicyd` crashes now and
/// again in that scan (`SecStaticCodeCheckValidity` ending in a null dereference, in the reports it leaves in /Library/Logs/DiagnosticReports,
/// more often while several builds and test runs share the machine), and a program that was started in that moment waits in `_dyld_start` and
/// never runs: the stand-in `curl` of a hook test never gets the end of its input, a stand-in tool never writes its file, and the test ends 5
/// or 600 seconds later. No wait of a different length mends that.
///
/// So a stub is not a new executable: it is a link to one launcher, which has been run before (it is made once and never deleted, so
/// macOS has scanned it once, ever), and the script itself is a data file beside the link, which the launcher hands to its interpreter. What
/// the code under test starts is the same file every time. The script runs with the same process id, arguments, input and environment
/// as if it had been started itself; only its `$0` differs: the path of the link, followed by `.body`.
enum StubTool {
    private static let launcherText = """
    #!/bin/sh
    # Runs "$0.body", the script this link stands for, with the interpreter of its first line.
    body="$0.body"
    IFS= read -r first < "$body"
    case "$first" in "#!"*) interpreter=${first#??} ;; *) interpreter=/bin/sh ;; esac
    exec $interpreter "$body" "$@"

    """

    /// The one executable every stub links to. Named by a hash of its text: a changed launcher is a new file, and an existing one is
    /// never written to (a file that is being written to cannot be started, and one that is being started cannot be written to).
    static let launcher: URL = {
        let fileManager = FileManager.default
        var hash: UInt64 = 5381
        for byte in launcherText.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let url = fileManager.temporaryDirectory.appendingPathComponent("nunsseop-test-launcher-" + String(hash, radix: 16))
        if fileManager.isExecutableFile(atPath: url.path) { return url }
        // Complete before it has its name: written elsewhere, made executable, then moved into place.
        let staging = url.appendingPathExtension(UUID().uuidString.prefix(8).lowercased())
        do {
            try launcherText.write(to: staging, atomically: false, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fileManager.removeItem(at: staging)
            Issue.record("the stub launcher could not be made: \(error)")
        }
        return url
    }()

    /// Makes `url` a program that runs `script` (whose first line says with what, `#!/bin/sh` mostly): the link at `url`, the script at `url + ".body"`.
    /// It may be called again for the same `url` to change the script.
    static func write(_ script: String, to url: URL) throws {
        let fileManager = FileManager.default
        try script.write(to: URL(fileURLWithPath: url.path + ".body"), atomically: true, encoding: .utf8)
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == launcher.path { return }
        try? fileManager.removeItem(at: url)
        try fileManager.createSymbolicLink(at: url, withDestinationURL: launcher)
    }

    /// A copy of a system program under another name, signed ad hoc (macOS ends a copy of a system binary that is not signed again), for a test
    /// that needs a program whose environment it may read, or whose name is another. It is made once and kept, for the reason the launcher is:
    /// a binary that is new to macOS is scanned, and one that is deleted while it is scanned is what `syspolicyd` stumbles over.
    static func signedCopy(of source: String, named name: String) throws -> URL {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("nunsseop-test-tool-\(name)")
        let url = folder.appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: url.path) { return url }
        let staging = fileManager.temporaryDirectory.appendingPathComponent("nunsseop-test-tool-\(UUID().uuidString.prefix(8))")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(name)
        try fileManager.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "--force", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Moved into place whole; a folder another run has made in the meantime is as good.
        _ = rename(staging.path, folder.path)
        guard fileManager.isExecutableFile(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    /// Removes a stub made by `write`.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".body")
    }
}

struct StubToolTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-stub-\(UUID().uuidString.prefix(6)) with space")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func run(_ executable: String, _ arguments: [String], stdin: String = "", environment: [String: String] = [:]) throws -> (out: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    @Test func aStubGetsItsArgumentsItsInputItsEnvironmentAndItsStatusAsAnyProgramWould() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        try StubTool.write("#!/bin/sh\nfor a; do printf '[%s]' \"$a\"; done; cat; echo \"$MARK\"; exit 3\n", to: tool)
        let result = try run(tool.path, ["a b", "", "$(x)"], stdin: "in", environment: ["MARK": "m"])
        #expect(result.out == "[a b][][$(x)]inm\n")
        #expect(result.status == 3)
    }

    @Test func aStubCanBeChangedLaterAndIsFoundByPath() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        try StubTool.write("#!/bin/sh\necho \"${0##*/}\"\n", to: tool)
        #expect(try run(tool.path, []).out == "tool.body\n")
        try StubTool.write("#!/bin/sh\necho changed\n", to: tool)
        #expect(try run(tool.path, []).out == "changed\n")
        // Found by PATH, as a hook's `curl` is.
        #expect(try run("/bin/sh", ["-c", "tool"], environment: ["PATH": dir.path + ":/usr/bin:/bin"]).out == "changed\n")
    }

    @Test func aStubRunsWithTheInterpreterOfItsFirstLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        try StubTool.write("#!/usr/bin/env python3\nimport sys\nprint(sys.argv[1:])\n", to: tool)
        #expect(try run(tool.path, ["x"]).out == "['x']\n")
    }

    @Test func allStubsStartTheSameFileSoNothingNewIsScanned() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("one"), second = dir.appendingPathComponent("two")
        try StubTool.write("#!/bin/sh\n", to: first)
        try StubTool.write("#!/bin/sh\necho different\n", to: second)
        let fileManager = FileManager.default
        #expect(try fileManager.destinationOfSymbolicLink(atPath: first.path) == StubTool.launcher.path)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: second.path) == StubTool.launcher.path)
        #expect(fileManager.isExecutableFile(atPath: StubTool.launcher.path))
    }

    /// A stand-in made the old way (written, `chmod 755`, run; a folder given its mode back is not one) is a new executable for macOS to scan, and the flakiness comes back with it.
    @Test func everyStandInIsMadeByTheHelper() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" && file.lastPathComponent != "StubTool.swift" {
            for (number, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("posixPermissions: 0o755") && line.contains("setAttributes") && !line.contains("folder.path") && !line.contains("support.path") {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "make a stand-in with StubTool.write: \(offenders)")
    }
}
