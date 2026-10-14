import AppKit

/// Orca (`com.stablyai.orca`), which runs the agents' CLIs in terminal panes of its own. It is reached only through its command-line
/// tool, which talks to the running app and fails when there is none (it never starts Orca, except `orca open`, which is never called).
/// Its `/hook` endpoint is not used: the hooks Nunsseop installs already see these sessions.
enum Orca {
    static let bundleID = "com.stablyai.orca"

    /// The tool inside the app: a script that runs Orca's own executable as Node on the CLI.
    static var cli: URL? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.appendingPathComponent("Contents/Resources/bin/orca")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Whether Orca has an ordinary window now (a minimized one or one on another Space counts). On macOS it keeps running after its
    /// last window is closed, and then makes a terminal as a hidden process nobody can see, whatever `--focus` says.
    static var hasWindow: Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid), window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return false }
            return bounds.width >= 200 && bounds.height >= 200
        }
    }

    /// The terminals of every worktree, as the CLI's JSON envelope (`{ok, result: {terminals, truncated, ...}}`). 1000 is far past the
    /// 200 the host lists by default.
    static let terminalListArguments = ["terminal", "list", "--json", "--limit", "1000"]

    /// The registered worktrees, as the same envelope. 10000 is the limit the CLI itself asks for when it looks for the current one.
    static let worktreeListArguments = ["worktree", "list", "--json", "--limit", "10000"]

    /// Runs the tool without Nunsseop's terminal variables (see `AgentSend.cleanEnvironment`, which also drops `ORCA_*`: they pick the
    /// instance, the paired server and the caller's own terminal the tool acts for).
    static func run(_ cli: URL, _ arguments: [String]) -> String? {
        TerminalFocus.run(cli, arguments, environment: AgentSend.cleanEnvironment)
    }

    /// The `result` of a successful reply of the tool's `--json`; nil for anything else.
    private static func result(in output: String) -> [String: Any]? {
        guard let reply = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              reply["ok"] as? Bool == true else { return nil }
        return reply["result"] as? [String: Any]
    }

    /// Whether a listing's entry is on this machine: one on an SSH host or a paired server has no process here.
    private static func isLocal(_ entry: [String: Any], key: String) -> Bool {
        (entry[key] as? String).map { $0 == "local" } ?? true
    }

    /// The handle of each live terminal pane in the output of `orca terminal list --json`, by pane key (`<tab id>:<leaf id>`, which is
    /// what `ORCA_PANE_KEY` holds). A pane the list holds twice is left out, as are a pane that is not connected, an orphaned PTY (no
    /// pane), one on another host and an entry whose ids or handle aren't plain. nil when the output is not a successful listing.
    static func panes(in output: String) -> [String: String]? {
        guard let terminals = result(in: output)?["terminals"] as? [[String: Any]] else { return nil }
        var handles: [String: String] = [:]
        var repeated = Set<String>()
        for terminal in terminals {
            guard terminal["connected"] as? Bool == true, terminal["orphaned"] as? Bool != true, isLocal(terminal, key: "executionHostId"),
                  let tab = terminal["tabId"] as? String, let leaf = terminal["leafId"] as? String,
                  let key = AgentInput.orcaPane(tab + ":" + leaf), let handle = AgentInput.orcaHandle(terminal["handle"] as? String) else { continue }
            if handles.updateValue(handle, forKey: key) != nil { repeated.insert(key) }
        }
        return handles.filter { !repeated.contains($0.key) }
    }

    /// The path, as Orca has it, of the worktree `folder` is in or is: the innermost of the registered ones that hold it. Orca's
    /// `path:` selector takes a worktree's own folder and nothing deeper. A worktree on another host, an archived one and one whose
    /// folder is gone are not candidates. nil when none holds it, or the output is not a successful listing.
    static func worktree(containing folder: String, in output: String) -> String? {
        guard let worktrees = result(in: output)?["worktrees"] as? [[String: Any]], let inner = canonical(folder) else { return nil }
        var best: (path: String, length: Int)?
        for worktree in worktrees {
            guard isLocal(worktree, key: "hostId"), worktree["isArchived"] as? Bool != true, worktree["prunable"] as? Bool != true,
                  let path = worktree["path"] as? String, Resume.isSafeFolder(path), let outer = canonical(path),
                  inner == outer || inner.hasPrefix(outer == "/" ? "/" : outer + "/"), outer.count > best?.length ?? -1 else { continue }
            best = (path, outer.count)
        }
        return best?.path
    }

    /// A folder with its symlinks and `/private` resolved the same way on both sides of a comparison.
    private static func canonical(_ path: String) -> String? {
        Ghostty.normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    /// The arguments of `orca terminal create` that open `script` (one plain path, see `Resume.isPlainPath`) in a new focused tab of the
    /// worktree. The command is typed into the tab's shell, so it must be nothing a shell reads as more than a path. `--json` because
    /// the plain output doesn't say whether the tab is on screen (see `isVisible`).
    static func createArguments(worktree: String, script: String) -> [String] {
        ["terminal", "create", "--worktree", "path:" + worktree, "--command", script, "--focus", "--json"]
    }

    /// Whether the reply of `terminal create --json` is a terminal in a tab on screen. One with no window to show it in is made
    /// anyway, as a hidden process, and answered with `surface: "background"` and a warning, and exit code 0.
    static func isVisible(created output: String) -> Bool {
        (result(in: output)?["terminal"] as? [String: Any])?["surface"] as? String == "visible"
    }
}

/// The handle `orca terminal list` gave the pane a row is in, which is how the tool addresses a terminal. Found again on every pass, so
/// a handle never outlives the listing it came from by more than the pass; a stale one makes the tool fail instead of reaching another pane.
struct OrcaPick: Equatable, Sendable {
    let paneKey: String
    let handle: String
}
