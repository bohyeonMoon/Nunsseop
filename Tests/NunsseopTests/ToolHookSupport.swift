import Foundation
@testable import Nunsseop

/// A tool's hook command run by `/bin/sh` against a stand-in `curl`, and what the server would make of what it sent.
enum ToolHook {
    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }

    /// The headers curl was given, by lowercased name, as the server reads them.
    static func headers(of run: ShellRun) -> [String: String] {
        var result: [String: String] = [:]
        var args = run.args[...]
        while let arg = args.popFirst() {
            guard arg == "-H", let header = args.popFirst(), !header.hasPrefix("@"), let colon = header.firstIndex(of: ":") else { continue }
            result[header[..<colon].lowercased()] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Runs `command` with `payload` on its standard input; the event the server would get, nil when the hook sent none.
    static func run(_ command: String, _ payload: [String: Any], environment: [String: String] = ["__CFBundleIdentifier": "com.mitchellh.ghostty"],
                    curlExit: Int32 = 0) throws -> (event: AgentEvent?, run: ShellRun) {
        let sent = try ShellRun.run({ _ in ["-c", command] }, stdin: json(payload), environment: environment, curlExit: curlExit)
        return (sent.curlCalls == 0 ? nil : AgentHook.event(headers: headers(of: sent), processes: ProcessTable { _ in nil }), sent)
    }
}
