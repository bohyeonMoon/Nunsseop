import Foundation
import Testing
@testable import Nunsseop

// Sessions in Orca's panes. Orca's tool is never run for real here: its JSON is made up in the shape of its types (a `--json` reply is
// `{id, ok, result, _meta}`, a terminal is a `RuntimeTerminalSummary`, a worktree a `RuntimeWorktreeRecord`), the plans are compared as
// values, and the one test that executes a step runs a stand-in script that only records its arguments and environment.

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let claudeExe = "/Users/me/.local/share/claude/versions/2.1"
private let orcaApp = "/Applications/Orca.app/Contents/MacOS/Orca"
private let orcaHost = "/Users/me/Library/Application Support/orca/daemon-host/macos/terminal-host-0a1b2c/app.noindex/Orca Terminal Host.app/Contents/MacOS/orca-terminal-host"
private let tab1 = "7d1e6f0a-4b2c-4a85-9c3d-0e5f1a2b3c4d", leaf1 = "2c9a0f1e-8b7d-4e6a-a1b2-c3d4e5f60718"
private let tab2 = "0b3c5d7e-1f20-4a31-8b42-5c6d7e8f9a0b", leaf2 = "9e8d7c6b-5a49-4382-9170-6f5e4d3c2b1a"
private let key1 = "\(tab1):\(leaf1)", key2 = "\(tab2):\(leaf2)"
private let handle1 = "term_5b9c3a52-8f1e-4c77-9a0d-6e2f4b1c8d33", handle2 = "term_c41d2e90-7b6a-4f58-8e13-2a9d5c7b0e64"
private let cli = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")

/// One entry of `result.terminals` of `orca terminal list --json`, with every field a `RuntimeTerminalSummary` carries.
private func terminal(_ handle: String, tab: String, leaf: String, connected: Bool = true, orphaned: Bool = false, host: String? = "local",
                      path: String = "/Users/me/proj") -> [String: Any] {
    var entry: [String: Any] = [
        "handle": handle, "ptyId": "pty-\(handle.suffix(4))", "incarnationId": NSNull(), "orphaned": orphaned,
        "worktreeId": "repo-1::\(path)", "worktreePath": path, "branch": "main", "tabId": tab, "leafId": leaf, "title": "claude",
        "connected": connected, "writable": true, "lastOutputAt": 1_790_000_000_000, "preview": "$ claude\n> secret prompt text",
    ]
    if let host { entry["executionHostId"] = host }
    return entry
}

private func reply(_ result: [String: Any], ok: Bool = true) -> String {
    let object: [String: Any] = ok ? ["id": "req_1", "ok": true, "result": result, "_meta": ["runtimeId": "rt_1"]]
                                   : ["id": "req_1", "ok": false, "error": ["code": "runtime_unavailable", "message": "Start the Orca app first."]]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

private func listing(_ terminals: [[String: Any]], truncated: Bool = false) -> String {
    reply(["terminals": terminals, "hostScope": ["hostIds": ["local"], "omittedHostIds": []], "topologyRevisions": [String: Int](),
           "totalCount": terminals.count, "truncated": truncated])
}

/// One entry of `result.worktrees` of `orca worktree list --json`: the fields of `Worktree` and `GitWorktreeInfo` the lookup reads.
private func worktree(_ path: String, host: String? = "local", archived: Bool = false, prunable: Bool? = nil) -> [String: Any] {
    var entry: [String: Any] = ["id": "repo-1::\(path)", "repoId": "repo-1", "displayName": (path as NSString).lastPathComponent, "isArchived": archived,
                                "path": path, "head": "abc123", "branch": "refs/heads/main", "isBare": false, "isMainWorktree": false,
                                "parentWorktreeId": NSNull(), "childWorktreeIds": [String]()]
    if let host { entry["hostId"] = host }
    if let prunable { entry["prunable"] = prunable }
    return entry
}

private func worktrees(_ entries: [[String: Any]]) -> String {
    reply(["worktrees": entries, "totalCount": entries.count, "truncated": false])
}

// MARK: ids

struct OrcaIdentifierTests {
    @Test func aPaneKeyIsATabIdAndTheLeafUUIDOrcaWrites() {
        #expect(AgentInput.orcaPane(key1) == key1)
        // Orca's tab ids are UUIDs, but a plain word is a tab id too.
        for tab in ["tab-1", "term.alpha_2", "A", String(repeating: "a", count: 64)] {
            #expect(AgentInput.orcaPane("\(tab):\(leaf1)") == "\(tab):\(leaf1)", Comment(rawValue: tab))
        }
    }

    @Test func anythingElseIsNotAPaneKey() {
        let bad: [String?] = [
            nil, "", ":", key1 + ":", ":" + leaf1, tab1, leaf1, tab1 + leaf1, "a:b:" + leaf1, "\(tab1):\(leaf1.uppercased())",
            "\(tab1):\(leaf1.dropLast())", "\(tab1):\(leaf1)0", "\(tab1):\(leaf1)\n", "\(tab1)\n:\(leaf1)", " \(key1)", "\(key1) ", "\(tab1) x:\(leaf1)",
            String(repeating: "a", count: 65) + ":" + leaf1, "a/b:\(leaf1)", "a;b:\(leaf1)", "$(id):\(leaf1)", "-x:\(leaf1)".replacingOccurrences(of: "x", with: "\u{0}"),
            // The version (1 to 5) and the variant (8 to b) of a UUID as Orca writes it.
            "\(tab1):2c9a0f1e-8b7d-0e6a-a1b2-c3d4e5f60718", "\(tab1):2c9a0f1e-8b7d-6e6a-a1b2-c3d4e5f60718", "\(tab1):2c9a0f1e-8b7d-4e6a-c1b2-c3d4e5f60718",
            "\(tab1):2c9a0f1e8b7d4e6aa1b2c3d4e5f60718", "\(tab1):2c9a0f1e-8b7d-4e6a-a1b2-c3d4e5f6071g", "\(tab1):../../etc/passwd",
            "\(tab1):\u{FF12}c9a0f1e-8b7d-4e6a-a1b2-c3d4e5f60718", String(repeating: "a", count: 200),
        ]
        for value in bad { #expect(AgentInput.orcaPane(value) == nil, Comment(rawValue: value?.debugDescription ?? "nil")) }
    }

    @Test func aHandleIsPlainAndNeverTakenForAnOption() {
        #expect(AgentInput.orcaHandle(handle1) == handle1)
        #expect(AgentInput.orcaHandle(String(repeating: "a", count: 128)) != nil)
        for bad in [nil, "", "--help", "-x", "term_1 2", "term_1\n", "term_1;id", "$(id)", "term/1", "term.1", "term_\u{FF11}", String(repeating: "a", count: 129)] as [String?] {
            #expect(AgentInput.orcaHandle(bad) == nil, Comment(rawValue: bad?.debugDescription ?? "nil"))
        }
    }
}

// MARK: the tool's JSON

struct OrcaListingTests {
    @Test func theLivePanesAreFoundByTheirKeyWithTheirHandles() throws {
        let output = listing([terminal(handle1, tab: tab1, leaf: leaf1), terminal(handle2, tab: tab2, leaf: leaf2, path: "/Users/me/other")])
        #expect(Orca.panes(in: output) == [key1: handle1, key2: handle2])
        #expect(Orca.terminalListArguments == ["terminal", "list", "--json", "--limit", "1000"])
    }

    @Test func aPaneThatIsNotAConnectedLocalPaneOfTheListIsNotListed() {
        let output = listing([
            terminal(handle1, tab: tab1, leaf: leaf1, connected: false),
            terminal("term_orphan", tab: tab2, leaf: leaf2, orphaned: true),
            terminal("term_remote", tab: "t3", leaf: "3f2e1d0c-9b8a-4776-8554-3a2b1c0d9e8f", host: "ssh:build-box"),
            terminal("term_runtime", tab: "t4", leaf: "4a3b2c1d-0e9f-4887-9665-4b3c2d1e0f9a", host: "runtime:paired"),
        ])
        #expect(Orca.panes(in: output) == [:])
        // An entry from a host too old to name its execution host is a local one.
        #expect(Orca.panes(in: listing([terminal(handle1, tab: tab1, leaf: leaf1, host: nil)])) == [key1: handle1])
    }

    @Test func aPaneListedTwiceIsLeftOutAndNeverGuessed() {
        let output = listing([terminal(handle1, tab: tab1, leaf: leaf1), terminal(handle2, tab: tab1, leaf: leaf1), terminal("term_other", tab: tab2, leaf: leaf2)])
        #expect(Orca.panes(in: output) == [key2: "term_other"])
    }

    @Test func entriesWithOddIdsOrHandlesAreSkippedNotTrusted() {
        let output = listing([
            terminal("--help", tab: tab1, leaf: leaf1), terminal("term x", tab: tab2, leaf: leaf2),
            terminal("term_a", tab: "t", leaf: "not-a-uuid"), terminal("term_b", tab: "a:b", leaf: leaf1),
            terminal("term_c", tab: "", leaf: leaf1), ["handle": "term_d"], ["connected": true],
            terminal("term_ok", tab: "tab-1", leaf: "5f4e3d2c-1b0a-4998-8776-5c4d3e2f1a0b"),
        ])
        #expect(Orca.panes(in: output) == ["tab-1:5f4e3d2c-1b0a-4998-8776-5c4d3e2f1a0b": "term_ok"])
    }

    @Test func aReplyThatIsNotASuccessfulListingGivesNone() {
        #expect(Orca.panes(in: reply([:], ok: false)) == nil)
        for output in ["", "not json", "[]", "{}", #"{"ok":true}"#, #"{"ok":true,"result":{}}"#, #"{"ok":true,"result":{"terminals":"x"}}"#,
                       #"{"ok":false,"result":{"terminals":[]}}"#, #"{"terminals":[]}"#, "Runtime unavailable"] {
            #expect(Orca.panes(in: output) == nil, Comment(rawValue: output))
        }
        #expect(Orca.panes(in: listing([])) == [:])
    }

    @Test func theWorktreeIsTheInnermostRegisteredOneHoldingTheFolder() {
        // The outer one is listed before and after the inner one: the order of the list decides nothing.
        let output = worktrees([worktree("/Users/me/repo"), worktree("/Users/me/repo/packages/web"), worktree("/Users/me/other")])
        let reversed = worktrees([worktree("/Users/me/repo/packages/web"), worktree("/Users/me/repo")])
        #expect(Orca.worktree(containing: "/Users/me/repo/packages/web/src", in: reversed) == "/Users/me/repo/packages/web")
        #expect(Orca.worktree(containing: "/Users/me/repo/packages/api", in: reversed) == "/Users/me/repo")
        #expect(Orca.worktree(containing: "/Users/me/repo", in: output) == "/Users/me/repo")
        #expect(Orca.worktree(containing: "/Users/me/repo/src/deep", in: output) == "/Users/me/repo")
        #expect(Orca.worktree(containing: "/Users/me/repo/packages/web", in: output) == "/Users/me/repo/packages/web")
        #expect(Orca.worktree(containing: "/Users/me/repo/packages/web/src", in: output) == "/Users/me/repo/packages/web")
        #expect(Orca.worktree(containing: "/Users/me/repo/packages/api", in: output) == "/Users/me/repo")
        #expect(Orca.worktreeListArguments == ["worktree", "list", "--json", "--limit", "10000"])
    }

    @Test func aFolderBesideAWorktreeOrOutsideAllIsInNone() {
        let output = worktrees([worktree("/Users/me/repo")])
        for folder in ["/Users/me/repo2", "/Users/me/repository/x", "/Users/me", "/", "/Users/me/other", "relative/repo", ""] {
            #expect(Orca.worktree(containing: folder, in: output) == nil, Comment(rawValue: folder))
        }
        #expect(Orca.worktree(containing: "/Users/me/repo", in: worktrees([])) == nil)
    }

    @Test func aWorktreeOfAnotherHostArchivedOrGoneIsNotOneToOpenATabIn() {
        let output = worktrees([worktree("/Users/me/a", host: "ssh:box"), worktree("/Users/me/b", archived: true), worktree("/Users/me/c", prunable: true),
                                worktree("/Users/me/d", host: "runtime:paired"), worktree("/Users/me/e", host: nil), worktree("/Users/me/f", prunable: false)])
        for folder in ["a", "b", "c", "d"] { #expect(Orca.worktree(containing: "/Users/me/\(folder)/src", in: output) == nil, Comment(rawValue: folder)) }
        #expect(Orca.worktree(containing: "/Users/me/e/src", in: output) == "/Users/me/e")
        #expect(Orca.worktree(containing: "/Users/me/f", in: output) == "/Users/me/f")
    }

    @Test func theFoldersAreComparedWithTheirSymlinksAndPrivatePrefixResolved() {
        // Orca may spell a worktree under /private/var where the session's folder is under /var, or the other way.
        #expect(Orca.worktree(containing: "/var/folders/ab/T/work/src", in: worktrees([worktree("/private/var/folders/ab/T/work")])) == "/private/var/folders/ab/T/work")
        #expect(Orca.worktree(containing: "/private/var/folders/ab/T/work", in: worktrees([worktree("/var/folders/ab/T/work")])) == "/var/folders/ab/T/work")
        #expect(Orca.worktree(containing: "/Users/me/repo/./src/../src", in: worktrees([worktree("/Users/me/repo")])) == "/Users/me/repo")
    }

    @Test func aReplyThatIsNotASuccessfulWorktreeListingGivesNoWorktree() {
        for output in ["", "nope", reply([:], ok: false), reply([:]), reply(["worktrees": "x"]), listing([])] {
            #expect(Orca.worktree(containing: "/Users/me/repo", in: output) == nil)
        }
        // A path with a control character is never handed to the tool.
        #expect(Orca.worktree(containing: "/Users/me/re\npo", in: worktrees([worktree("/Users/me/re\npo")])) == nil)
    }
}

// MARK: plans

struct OrcaStepsTests {
    private let tools = TerminalCLIs(orca: cli)
    private let pick = OrcaPick(paneKey: key1, handle: handle1)

    @Test func aMessageIsTheTextWithTheTextAsOneArgumentThenAnEnterOfItsOwn() throws {
        // Together (`--text --enter`) Orca holds the call for the render gate of a working Claude Code or Codex, longer than the tool
        // is given, and writes text and Return in one go for older builds and other agents; so the Return is a call with no text.
        let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: "run the tests", submit: true, clis: tools, orca: pick))
        #expect(steps == [.run(cli, ["terminal", "send", "--terminal", handle1, "--text=run the tests"]),
                          .run(cli, ["terminal", "send", "--terminal", handle1, "--enter"])])
        for case .run(_, let arguments) in steps { #expect(!(arguments.contains("--enter") && arguments.contains { $0.hasPrefix("--text") })) }
    }

    @Test func theEnterIsNotSentWhenTheTextFailed() throws {
        // A stand-in tool that fails on a text: the Return call would otherwise submit whatever was in the prompt already.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-orca-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("orca")
        try StubTool.write("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(dir.path)/log\"\ncase \"$*\" in *--text=*) exit 1;; esac\n", to: tool)
        let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: "x", submit: true, clis: TerminalCLIs(orca: tool), orca: pick))
        #expect(AgentSend.run(steps) == .failed)
        #expect(try String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8) == "terminal send --terminal \(handle1) --text=x\n")
    }

    @Test func droppedPathsAreTypedWithoutEnter() throws {
        let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: "'/tmp/a b.png' /tmp/c.txt ", submit: false, clis: tools, orca: pick))
        #expect(steps == [.run(cli, ["terminal", "send", "--terminal", handle1, "--text='/tmp/a b.png' /tmp/c.txt "])])
        #expect(AgentInput.orca(paneKey: key1).takesFiles)
    }

    @Test func whateverTheTextHoldsItStaysOneArgumentOfTheTool() throws {
        // The tool takes a value starting with `--` for an option unless it is joined with `=`; it reads no escapes, so a backslash goes
        // through as it is; and nothing is run through a shell.
        let hostile = ["--help", "--enter", "--terminal x", "-x", "line\\n\\r\\t\\u0041", "$(touch pwn); `id` | cat > x", "'q' \"d\" \\", "a=b=c", "--text=--text=x"]
        for text in hostile {
            let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: text, submit: true, clis: tools, orca: pick))
            #expect(steps == [.run(cli, ["terminal", "send", "--terminal", handle1, "--text=" + text]),
                              .run(cli, ["terminal", "send", "--terminal", handle1, "--enter"])], Comment(rawValue: text))
            guard case .run(let tool, let arguments)? = steps.first else { Issue.record("not a command"); continue }
            #expect(tool == cli && !arguments.contains("-c") && arguments.filter { $0.hasPrefix("--") && !$0.hasPrefix("--text=") }.count == 1)
        }
    }

    @Test func withoutTheToolOrThePanesOwnHandleThereIsNoPlan() {
        let input = AgentInput.orca(paneKey: key1)
        #expect(AgentSend.steps(input, text: "x", submit: true, clis: TerminalCLIs(), orca: pick) == nil)
        #expect(AgentSend.steps(input, text: "x", submit: true, clis: tools) == nil)
        // The handle found for another pane is never used for this one.
        #expect(AgentSend.steps(input, text: "x", submit: true, clis: tools, orca: OrcaPick(paneKey: key2, handle: handle2)) == nil)
        #expect(AgentFocus.steps(input, clis: tools, ghostty: nil) == nil)
        #expect(AgentFocus.steps(input, clis: tools, ghostty: nil, orca: OrcaPick(paneKey: key2, handle: handle2)) == nil)
        #expect(AgentFocus.steps(input, clis: TerminalCLIs(), ghostty: nil, orca: pick) == nil)
    }

    @Test func aPaneIsFocusedByTheSameHandleAndOrcaIsBroughtForward() throws {
        let input = AgentInput.orca(paneKey: key1)
        #expect(AgentFocus.steps(input, clis: tools, ghostty: nil, orca: pick) == [.run(cli, ["terminal", "switch", "--terminal", handle1])])
        #expect(AgentFocus.bundleID(of: input) == "com.stablyai.orca" && Orca.bundleID == "com.stablyai.orca")
        let agent = AgentBoard.Agent(state: .working, since: start, tool: "claude", input: input, pid: 100)
        let verified = AgentRow(AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent), transcript: nil, inputVerified: true)
        #expect(AgentFocus.plan(for: verified, clis: tools, orca: pick) == .terminal([.run(cli, ["terminal", "switch", "--terminal", handle1])], app: "com.stablyai.orca"))
        // Verified but without a handle (or a tool): only Orca comes forward. Unverified: only the app the hook named, if any.
        #expect(AgentFocus.plan(for: verified, clis: tools) == .app("com.stablyai.orca"))
        let unverified = AgentRow(AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent), transcript: nil, inputVerified: false)
        #expect(AgentFocus.plan(for: unverified, clis: tools, orca: pick) == .nothing)
    }

    @Test func theToolIsRunWithOrcasVariablesAndNunsseopsTerminalOnesTakenOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-orca-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stand-in for the tool: it records its arguments and the variables that would pick the instance, the server or the terminal.
        let tool = dir.appendingPathComponent("orca")
        try StubTool.write("#!/bin/sh\nfor a; do printf '%s\\n' \"$a\"; done >> \"\(dir.path)/args\"\n"
                           + "echo \"[${ORCA_PANE_KEY-unset}][${ORCA_USER_DATA_PATH-unset}][${ORCA_ENVIRONMENT-unset}][${ORCA_TERMINAL_HANDLE-unset}][${ORCA_PAIRING_CODE-unset}][${MUXY_SESSION_ID-unset}]\" > \"\(dir.path)/env\"\n", to: tool)
        let names = ["ORCA_PANE_KEY", "ORCA_USER_DATA_PATH", "ORCA_ENVIRONMENT", "ORCA_TERMINAL_HANDLE", "ORCA_PAIRING_CODE", "MUXY_SESSION_ID"]
        let saved = names.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for name in names { setenv(name, "x", 1) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }

        let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: "--help $(touch pwn) \\n", submit: true, clis: TerminalCLIs(orca: tool), orca: pick))
        #expect(AgentSend.run(steps) == .sent)
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
                == "terminal\nsend\n--terminal\n\(handle1)\n--text=--help $(touch pwn) \\n\nterminal\nsend\n--terminal\n\(handle1)\n--enter\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[unset][unset][unset][unset][unset][unset]\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwn").path))
        // The listing the verification reads goes through the same clean environment.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("env"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("args"))
        _ = Orca.run(tool, Orca.terminalListArguments)
        #expect(try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8) == "[unset][unset][unset][unset][unset][unset]\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8) == "terminal\nlist\n--json\n--limit\n1000\n")
    }

    @Test func aToolThatFailsFailsTheStep() throws {
        // `orca terminal send` exits 1 when Orca does not accept the input, and the tool fails outright when Orca is not running.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-orca-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("orca")
        try StubTool.write("#!/bin/sh\nexit 1\n", to: tool)
        let steps = try #require(AgentSend.steps(.orca(paneKey: key1), text: "x", submit: true, clis: TerminalCLIs(orca: tool), orca: pick))
        #expect(AgentSend.run(steps) == .failed)
        #expect(Orca.run(tool, Orca.terminalListArguments) == nil)
    }
}

// MARK: the process tree

private final class OrcaCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func update(_ change: (inout Int) -> Void) { lock.withLock { change(&count) } }
}

struct OrcaHostTests {
    private func check(_ records: [Int32: ProcessRecord], list: String? = nil, running: Bool = true, calls: OrcaCounter = OrcaCounter()) -> AgentTargetCheck {
        AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil },
                         orcaList: { _ in calls.update { $0 += 1 }; return list }, orcaRunning: { running })
    }

    /// claude, its shell, `login` (which Orca's host runs the shell through), the host.
    private func tree(host: String = orcaApp, between: String? = nil) -> [Int32: ProcessRecord] {
        var records: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: claudeExe, hasTTY: true), 101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 103, executable: "/usr/bin/login", hasTTY: true), 103: .init(parent: 1, executable: host, hasTTY: false),
        ]
        if let between { records[102] = .init(parent: 104, executable: "/usr/bin/login", hasTTY: true); records[104] = .init(parent: 103, executable: between, hasTTY: false) }
        return records
    }

    @Test func aSessionUnderOrcasHostThroughItsShellAndLoginIsInOrca() {
        let input = AgentInput.orca(paneKey: key1)
        // Forked from the app (the host is then Orca's own executable, and outlives the app), or Orca's signed helper under launchd.
        for host in [orcaApp, "/Users/me/Applications/Orca.app/Contents/MacOS/Orca", orcaHost] {
            #expect(check(tree(host: host)).hosted(input, pid: 100), Comment(rawValue: host))
        }
    }

    @Test func anotherTerminalOrMultiplexerBetweenMeansTheSessionIsNotInOrcaItself() {
        let input = AgentInput.orca(paneKey: key1)
        for path in ["/opt/homebrew/bin/tmux", "/opt/homebrew/bin/zellij", "/usr/bin/screen", "/Users/me/.local/bin/herdr",
                     "/Applications/Ghostty.app/Contents/MacOS/ghostty", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                     "/Applications/Muxy.app/Contents/MacOS/muxy-server"] {
            #expect(!check(tree(between: path)).hosted(input, pid: 100), Comment(rawValue: path))
        }
        #expect(check(tree(between: "/usr/bin/caffeinate")).hosted(input, pid: 100))
    }

    @Test func aSessionWithoutATerminalOrWithAnotherSessionAboveItIsNotInOrca() {
        let input = AgentInput.orca(paneKey: key1)
        var headless = tree()
        headless[100] = .init(parent: 101, executable: claudeExe, hasTTY: false)
        #expect(!check(headless).hosted(input, pid: 100))
        var child = tree()
        child[100] = .init(parent: 99, executable: claudeExe, hasTTY: true)
        child[99] = .init(parent: 101, executable: claudeExe, hasTTY: true)
        #expect(!check(child).hosted(input, pid: 100, others: [99, 100]))
        #expect(check(child).hosted(input, pid: 100, others: [100]))
        // Orca's helpers (renderer, GPU) and its tool are not the host.
        for path in ["/Applications/Orca.app/Contents/Frameworks/Orca Helper (Renderer).app/Contents/MacOS/Orca Helper (Renderer)",
                     "/Applications/Orca.app/Contents/Resources/bin/orca", "/usr/local/bin/orca"] {
            #expect(!check(tree(host: path)).hosted(input, pid: 100), Comment(rawValue: path))
        }
        #expect(!check([:]).hosted(input, pid: 100) && !check(tree()).hosted(input, pid: nil))
    }

    @Test func onlyOrcasOwnExecutablesAreOrca() {
        #expect(AgentTargetCheck.isOrca(orcaApp) && AgentTargetCheck.isOrca(orcaHost))
        for path in ["/Applications/Orca.app/Contents/MacOS/other", "/usr/local/bin/Orca", "/Applications/NotOrca.app/Contents/MacOS/Orca",
                     "/Applications/Orca.app/Contents/MacOS/orca-terminal-host", "/Applications/Other.app/Contents/MacOS/orca-terminal-host", ""] {
            #expect(!AgentTargetCheck.isOrca(path), Comment(rawValue: path))
        }
        #expect(AgentTargetCheck.hostsInput(orcaApp) && AgentRow.inputApps.contains("com.stablyai.orca"))
    }

    @Test func theProcessIsNotEnoughTheListingMustHoldThePaneToo() {
        let input = AgentInput.orca(paneKey: key1)
        let panes = [key1: handle1]
        #expect(check(tree()).verified(input, pid: 100, muxySessions: nil, orcaPanes: panes))
        #expect(!check(tree()).verified(input, pid: 100, muxySessions: nil, orcaPanes: [key2: handle2]))
        #expect(!check(tree()).verified(input, pid: 100, muxySessions: nil, orcaPanes: [:]))
        #expect(!check(tree()).verified(input, pid: 100, muxySessions: nil, orcaPanes: nil))
        #expect(!check(tree(between: "/opt/homebrew/bin/tmux")).verified(input, pid: 100, muxySessions: nil, orcaPanes: panes))
    }

    @Test func theListingIsReadOnlyWhileOrcaRunsAndOnlyThroughTheTool() {
        let output = listing([terminal(handle1, tab: tab1, leaf: leaf1)])
        let calls = OrcaCounter()
        #expect(check([:], list: output, calls: calls).orcaPanes(cli: cli) == [key1: handle1] && calls.value == 1)
        // Orca not running (its tool would only fail), no tool, a tool that fails or answers with something else: none, and nothing is guessed.
        #expect(check([:], list: output, running: false, calls: calls).orcaPanes(cli: cli) == nil && calls.value == 1)
        #expect(check([:], list: output, calls: calls).orcaPanes(cli: nil) == nil && calls.value == 1)
        #expect(check([:], list: nil, calls: calls).orcaPanes(cli: cli) == nil && calls.value == 2)
        #expect(check([:], list: "garbage", calls: calls).orcaPanes(cli: cli) == nil)
    }
}

// MARK: the hook

struct OrcaHookTests {
    private let base = ["x-session": "s", "x-event": "Stop"]

    @Test func theHookEventCarriesTheOrcaPane() {
        #expect(AgentHook.event(headers: base.merging(["x-orca": key1]) { $1 })?.input == .orca(paneKey: key1))
        #expect(AgentHook.event(headers: base.merging(["x-orca": key1, "x-agent": "codex"]) { $1 })?.input == .orca(paneKey: key1))
        // Whatever is not a pane key leaves the session without a target, and nothing else.
        for junk in ["", "x", leaf1, "\(tab1):\(leaf1)\n", "\(tab1):\(leaf1.uppercased())", "a:b", "$(id)", "../x"] {
            let event = AgentHook.event(headers: base.merging(["x-orca": junk]) { $1 })
            #expect(event != nil && event?.input == nil, Comment(rawValue: junk))
        }
    }

    @Test func aSessionInAMultiplexerAHerdrPaneOrTheBackgroundHasNoOrcaTarget() {
        // Orca puts its pane key in the environment of the shell; the multiplexer inside it, and a background session's daemon, inherit it.
        let headers = base.merging(["x-orca": key1]) { $1 }
        #expect(AgentHook.event(headers: headers.merging(["x-mux": "1"]) { $1 })?.input == nil)
        #expect(AgentHook.event(headers: headers.merging(["x-herdr": "1"]) { $1 })?.input == nil)
        #expect(AgentHook.event(headers: headers.merging(["x-background": "1"]) { $1 })?.input == nil)
    }

    @Test func whenSeveralTerminalsVariablesAreThereTheOneTheProcessIsInIsTaken() {
        let wezSocket = "/Users/me/.local/share/wezterm/gui-sock-1200"
        let both = base.merging(["x-orca": key1, "x-wezterm": "7", "x-wezterm-socket": wezSocket]) { $1 }
        // Orca started from a WezTerm shell passes WezTerm's variables on to its panes.
        let tree: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: claudeExe, hasTTY: true), 101: .init(parent: 102, executable: "/usr/bin/login", hasTTY: true),
            102: .init(parent: 1, executable: orcaApp, hasTTY: false),
        ]
        let event = AgentHook.event(headers: both.merging(["x-pid": "100"]) { $1 }, processes: ProcessTable { tree[$0] })
        #expect(event?.input == .orca(paneKey: key1))
        // Without a process to look at, the first candidate is kept and the verification refuses it later.
        #expect(AgentHook.event(headers: both)?.input == .wezterm(pane: "7", socket: wezSocket))
        #expect(AgentHook.input(muxy: nil, cmux: nil, orca: key1) == .orca(paneKey: key1))
        #expect(AgentHook.input(muxy: "42", cmux: nil, orca: key1) == .muxy("42"))
    }

    @Test func aSessionWhoseHookNamedNoneIsLookedUpInItsOwnEnvironment() {
        #expect(ProcessEnvironment.keys.contains("ORCA_PANE_KEY"))
        // Only the pane key is taken of Orca's variables: its hook endpoint's port and token, and the launch token, are never read.
        #expect(!ProcessEnvironment.keys.contains { $0.hasPrefix("ORCA_") && $0 != "ORCA_PANE_KEY" })
        let environment = ProcessEnvironment { _ in ["ORCA_PANE_KEY": key1, "ORCA_AGENT_HOOK_TOKEN": "secret", "ORCA_AGENT_HOOK_PORT": "1", "ORCA_AGENT_LAUNCH_TOKEN": "t", "ORCA_TAB_ID": tab1] }
        #expect(environment.variables(of: 100) == ["ORCA_PANE_KEY": key1])
        #expect(AgentHook.input(environment: ["ORCA_PANE_KEY": key1], app: nil) == .orca(paneKey: key1))
        #expect(AgentHook.input(environment: ["ORCA_PANE_KEY": "junk"], app: nil) == nil)
        #expect(AgentHook.input(environment: ["ORCA_PANE_KEY": key1, "TMUX": "/tmp/tmux-501/default,1,0"], app: nil) == nil)
        #expect(AgentHook.input(environment: ["ORCA_PANE_KEY": key1, "HERDR_PANE_ID": "p"], app: nil) == nil)
    }

    @Test func everyHookThatReportsSessionsSendsThePaneKeyAndNeverOrcasHookEndpoint() {
        for command in [NotifyServer.agentHookCommand, NotifyServer.agentHookCommand(for: .codex)] {
            #expect(command.contains(#"-H "X-Orca: ${ORCA_PANE_KEY}""#) && !command.contains("ORCA_AGENT_HOOK") && !command.contains("/hook"))
        }
        for agent in [AgentKind.omp, .omo, .pi] {
            let source = PiExtension.source(agent: agent)
            #expect(source.contains(#""X-Orca": clean(env.ORCA_PANE_KEY),"#) && !source.contains("ORCA_AGENT_HOOK"))
        }
        let plugin = OpenCodePlugin.source()
        #expect(plugin.contains(#""X-Orca": clean(env.ORCA_PANE_KEY),"#) && !plugin.contains("ORCA_AGENT_HOOK"))
    }
}

// MARK: the model

private final class Plans: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[AgentStep]] = []
    private var log: [String] = []
    var passes = true

    var sent: [[AgentStep]] { lock.withLock { all } }
    var focusLog: [String] { lock.withLock { log } }

    var sender: AgentSender {
        AgentSender { [self] steps in lock.withLock { all.append(steps); return passes ? .sent : .failed } }
    }

    var focuser: AgentFocuser {
        AgentFocuser(run: { [self] steps in lock.withLock { all.append(steps); log.append("run"); return passes ? .sent : .failed } },
                     activate: { [self] app in lock.withLock { log.append("activate:\(app)") } }, herdr: { _, _ in })
    }
}

/// Orca's list as the model asks for it: what it answers, whether Orca runs, and how often it was asked.
private final class FakeOrca: @unchecked Sendable {
    private let lock = NSLock()
    private var output: String?
    private var up = true
    private var asked = 0
    init(_ output: String?) { self.output = output }
    var answer: String? { get { lock.withLock { output } } set { lock.withLock { output = newValue } } }
    var running: Bool { get { lock.withLock { up } } set { lock.withLock { up = newValue } } }
    var listings: Int { lock.withLock { asked } }
    var targets: (@Sendable (URL) -> String?, @Sendable () -> Bool) {
        ({ [self] _ in lock.withLock { asked += 1; return output } }, { [self] in lock.withLock { up } })
    }
}

@MainActor
struct OrcaModelTests {
    /// 100, 110: sessions in Orca (host forked from the app, and the helper copy); 120: in tmux in Orca; 130: no terminal; 140: under Ghostty.
    private var tree: [Int32: ProcessRecord] {
        var records: [Int32: ProcessRecord] = [
            10: .init(parent: 1, executable: orcaApp, hasTTY: false), 11: .init(parent: 10, executable: "/usr/bin/login", hasTTY: true),
            20: .init(parent: 1, executable: orcaHost, hasTTY: false), 21: .init(parent: 20, executable: "/usr/bin/login", hasTTY: true),
            122: .init(parent: 11, executable: "/opt/homebrew/bin/tmux", hasTTY: false),
            142: .init(parent: 1, executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty", hasTTY: false),
        ]
        for (pid, parent) in [(Int32(100), Int32(11)), (110, 21), (120, 122), (140, 142)] {
            records[pid] = .init(parent: pid + 1, executable: claudeExe, hasTTY: true)
            records[pid + 1] = .init(parent: parent, executable: "/bin/zsh", hasTTY: true)
        }
        records[130] = .init(parent: 131, executable: claudeExe, hasTTY: false)
        records[131] = .init(parent: 11, executable: "/bin/zsh", hasTTY: true)
        return records
    }

    private func agent(_ input: AgentInput?, pid: Int32?, state: AgentBoard.State = .working, app: String? = "com.stablyai.orca") -> AgentBoard.Agent {
        AgentBoard.Agent(state: state, since: start, tool: "claude", app: app, input: input, pid: pid)
    }

    private func make(_ agents: [String: AgentBoard.Agent], orca: FakeOrca, plans: Plans = Plans(), tools: TerminalCLIs = TerminalCLIs(orca: cli)) async -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let records = tree
        let (list, running) = orca.targets
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: plans.sender, clis: { tools },
                                   targets: AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil }, orcaList: list, orcaRunning: running),
                                   environments: ProcessEnvironment { _ in [:] }, scripts: AppleScriptRunner { _ in .failed }, focuser: plans.focuser)
        model.noteDuration = eventDeadline
        model.fixedRecent = []
        await refresh(model)
        return model
    }

    private func refresh(_ model: AgentsTabModel) async {
        model.refresh(now: start)
        await eventually { !model.verifying }
    }

    private func row(_ model: AgentsTabModel, _ id: String) throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    private var both: String {
        listing([terminal(handle1, tab: tab1, leaf: leaf1), terminal(handle2, tab: tab2, leaf: leaf2, path: "/Users/me/other")])
    }

    @Test func aSessionInAnOrcaPaneTakesMessagesAndDropsByTheHandleOfItsPane() async throws {
        let plans = Plans(), orca = FakeOrca(both)
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100), "b": agent(.orca(paneKey: key2), pid: 110)], orca: orca, plans: plans)
        let a = try row(model, "a"), b = try row(model, "b")
        #expect(a.offersInput && a.acceptsInput && a.inputBlock == nil && b.acceptsInput)
        #expect(model.send(message: "  run the tests\n", to: a))
        await eventually { plans.sent.count == 1 }
        #expect(model.send(files: [URL(fileURLWithPath: "/tmp/a b.png")], to: b))
        await eventually { plans.sent.count == 2 }
        #expect(plans.sent == [
            [.run(cli, ["terminal", "send", "--terminal", handle1, "--text=run the tests"]), .run(cli, ["terminal", "send", "--terminal", handle1, "--enter"])],
            [.run(cli, ["terminal", "send", "--terminal", handle2, "--text='/tmp/a b.png' "])],
        ])
        #expect(model.notes.isEmpty)
    }

    @Test func theListIsAskedOncePerPassForAllTheSessionsAndOnlyWhenOneIsInOrca() async throws {
        let orca = FakeOrca(both)
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100), "b": agent(.orca(paneKey: key2), pid: 110)], orca: orca)
        #expect(orca.listings == 1)
        await refresh(model)
        #expect(orca.listings == 2)
        let none = FakeOrca(both)
        _ = await make(["x": agent(nil, pid: 130), "y": agent(.herdr(pane: "p", socket: "/tmp/h.sock"), pid: nil)], orca: none)
        #expect(none.listings == 0)
    }

    @Test func aSessionWhosePaneIsNotListedOrWhoseOrcaIsNotRunningIsUnconfirmed() async throws {
        let orca = FakeOrca(listing([terminal(handle2, tab: tab2, leaf: leaf2)]))
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100), "b": agent(.orca(paneKey: key2), pid: 110)], orca: orca)
        let gone = try row(model, "a")
        #expect(!gone.offersInput && !gone.acceptsInput && gone.inputBlock == .unconfirmed)
        #expect(gone.blockReason == AgentRow.InputBlock.unconfirmed.message && gone.focusable)
        #expect(try row(model, "b").acceptsInput)
        // Orca quits: its tool would fail, so it is not asked, and nothing is sendable.
        orca.running = false
        let before = orca.listings
        await refresh(model)
        #expect(orca.listings == before)
        #expect(try !row(model, "b").offersInput && row(model, "b").inputBlock == .unconfirmed)
        // A tool that fails or answers with something else is the same.
        orca.running = true
        orca.answer = nil
        await refresh(model)
        #expect(try !row(model, "b").offersInput)
        orca.answer = "Orca is not running"
        await refresh(model)
        #expect(try !row(model, "b").offersInput)
        orca.answer = both
        await refresh(model)
        #expect(try row(model, "b").acceptsInput)
    }

    @Test func thePaneKeyAloneIsNotTheProof() async throws {
        let orca = FakeOrca(both)
        // 120 is in tmux in Orca, 130 has no terminal, 140 runs under Ghostty: each names an Orca pane that is listed.
        let model = await make(["tmux": agent(.orca(paneKey: key1), pid: 120), "headless": agent(.orca(paneKey: key1), pid: 130),
                                "ghostty": agent(.orca(paneKey: key2), pid: 140, app: "com.mitchellh.ghostty"),
                                "noprocess": agent(.orca(paneKey: key1), pid: nil)], orca: orca)
        for id in ["tmux", "headless", "ghostty", "noprocess"] { #expect(try !row(model, id).offersInput, Comment(rawValue: id)) }
    }

    @Test func aPaneListedTwiceIsNeverGuessedAt() async throws {
        let orca = FakeOrca(listing([terminal(handle1, tab: tab1, leaf: leaf1), terminal(handle2, tab: tab1, leaf: leaf1)]))
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100)], orca: orca)
        #expect(try !row(model, "a").offersInput)
    }

    @Test func aSessionWaitingOnAPromptIsNotSentTo() async throws {
        let plans = Plans()
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100, state: .waiting)], orca: FakeOrca(both), plans: plans)
        let waiting = try row(model, "a")
        #expect(waiting.offersInput && !waiting.acceptsInput && waiting.inputBlock == .prompt)
        #expect(!model.send(message: "yes", to: waiting))
        try await Task.sleep(for: .milliseconds(100))
        #expect(plans.sent.isEmpty)
    }

    @Test func withoutTheToolNoOrcaRowIsOfferedAndNothingIsRun() async throws {
        let plans = Plans()
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100)], orca: FakeOrca(both), plans: plans, tools: TerminalCLIs())
        let target = try row(model, "a")
        // The listing that proves the pane needs the tool, so without it the row is not offered at all.
        #expect(!target.offersInput)
        #expect(!model.send(message: "hello", to: target))
        #expect(plans.sent.isEmpty)
    }

    @Test func aFailedSendLeavesANoteAndTheHandleIsFoundAgain() async throws {
        let plans = Plans(), orca = FakeOrca(both)
        plans.passes = false
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100)], orca: orca, plans: plans)
        let target = try row(model, "a")
        #expect(model.send(message: "hello", to: target))
        await eventually { model.notes[target.id] != nil }
        #expect(model.notes[target.id] == String(localized: "Couldn't send to this session"))
        // The pane is gone from Orca's list by the next pass: the row stops offering input.
        orca.answer = listing([])
        await eventually { !model.verifying }
        await refresh(model)
        #expect(try !row(model, "a").offersInput)
        #expect(!model.send(message: "again", to: try row(model, "a")))
    }

    @Test func aClickSwitchesToThePaneThenBringsOrcaForward() async throws {
        let plans = Plans()
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100)], orca: FakeOrca(both), plans: plans)
        model.focus(try row(model, "a"))
        await eventually { plans.focusLog.count == 2 }
        #expect(plans.sent == [[.run(cli, ["terminal", "switch", "--terminal", handle1])]])
        #expect(plans.focusLog == ["run", "activate:com.stablyai.orca"])
    }

    @Test func aClickOnASessionThatLeftItsPaneOnlyBringsOrcaForward() async throws {
        let plans = Plans()
        let model = await make(["a": agent(.orca(paneKey: key1), pid: 100)], orca: FakeOrca(both), plans: plans)
        let drawn = try row(model, "a")
        // After the row was drawn, the session's shell moved under another app.
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: ["a": agent(.orca(paneKey: key1), pid: 140)], now: start)
        let (list, running) = FakeOrca(both).targets
        var records = tree
        records[141] = .init(parent: 142, executable: "/bin/zsh", hasTTY: true)
        let moved = records
        let later = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: plans.sender, clis: { TerminalCLIs(orca: cli) },
                                   targets: AgentTargetCheck(processes: ProcessTable { moved[$0] }, muxyList: { _ in nil }, orcaList: list, orcaRunning: running),
                                   environments: ProcessEnvironment { _ in [:] }, scripts: AppleScriptRunner { _ in .failed }, focuser: plans.focuser)
        later.noteDuration = eventDeadline
        later.fixedRecent = []
        await refresh(later)
        later.focus(drawn)
        await eventually { !plans.focusLog.isEmpty }
        #expect(plans.sent.isEmpty && !plans.focusLog.contains("run"))
        #expect(plans.focusLog == ["activate:com.stablyai.orca"])
    }
}

// MARK: resume

private final class Calls {
    var calls: [(program: String, arguments: [String])] = []
    /// What each program answers (nil: it fails), by its name and first argument.
    var answers: [String: String?] = [:]
    var launcher: Resume.Launcher {
        Resume.Launcher(run: { url, arguments in
            self.calls.append((url.lastPathComponent, arguments))
            let name = url.lastPathComponent + ":" + (arguments.first ?? "")
            return self.answers[name] ?? ""
        }, sleep: { _ in })
    }
}

private func folder(_ name: String) throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-orca-\(UUID().uuidString.prefix(8))/\(name)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// The reply of `orca terminal create --json`: a `RuntimeTerminalCreate` in the envelope, with the warning a hidden one carries.
private func created(surface: String?) -> String {
    var terminal: [String: Any] = ["handle": handle1, "worktreeId": "repo::/Users/me/repo", "title": NSNull()]
    if let surface { terminal["surface"] = surface }
    if surface == "background" { terminal["warning"] = "Terminal was created but could not be shown." }
    return reply(["terminal": terminal])
}

private func setup(running: Set<String> = ["com.stablyai.orca"], window: Bool = true, scripts: URL, orcaCLI: URL? = cli) -> Resume.Setup {
    // No app counts as running but those named, and no Apple Event goes out.
    Resume.Setup(installed: ResumeTerminal.allCases, ghostty: URL(fileURLWithPath: "/Applications/Ghostty.app"), orcaCLI: orcaCLI, orcaHasWindow: window, running: running,
                 isRunning: { _ in false }, appleScript: AppleScriptRunner { _ in .failed }, shell: "/bin/zsh", scripts: scripts)
}

private let session = "5f0c2d1e-0000-4000-8000-000000000001"

struct OrcaResumeTests {
    private func conversation(_ cwd: String, kind: AgentKind = .claude) -> RecentConversation {
        RecentConversation(kind: kind, session: session, cwd: cwd, modified: .now)
    }

    @Test func orcaIsOfferedWhileItRunsWithItsToolAndAppOnly() {
        let app: (ResumeTerminal) -> URL? = { _ in URL(fileURLWithPath: "/Applications/X.app") }
        func installed(app: @escaping (ResumeTerminal) -> URL? = app, tool: URL? = cli, running: Bool) -> [ResumeTerminal] {
            ResumeTerminal.installed(appURL: app, weztermInstalled: false, kittyCLI: nil, kittySocket: nil, socketExists: { _ in false }, orcaCLI: tool, orcaRunning: running)
        }
        #expect(installed(running: true).contains(.orca))
        #expect(!installed(running: false).contains(.orca) && !installed(tool: nil, running: true).contains(.orca))
        #expect(!installed(app: { $0 == .orca ? nil : URL(fileURLWithPath: "/Applications/X.app") }, running: true).contains(.orca))
        // A saved choice of Orca that is not offered falls back to Ghostty.
        #expect(ResumeTerminal.effective(saved: "orca", installed: installed(running: true)) == .orca)
        #expect(ResumeTerminal.effective(saved: "orca", installed: installed(running: false)) == .ghostty)
        #expect(ResumeTerminal.orca.name == "Orca" && ResumeTerminal.orca.bundleID == "com.stablyai.orca")
    }

    @Test func aNewFocusedTabOfTheWorktreeRunsAPlainScriptAndOrcaComesForward() throws {
        let cwd = try folder("repo/src/deep")
        let root = URL(fileURLWithPath: cwd).deletingLastPathComponent().deletingLastPathComponent().path
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree("/elsewhere/repo"), worktree(root)])
        calls.answers["orca:terminal"] = created(surface: "visible")
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts), launcher: calls.launcher) == .orca)
        #expect(calls.calls.map { $0.program + " " + ($0.arguments.first ?? "") } == ["orca worktree", "orca terminal", "open -b"])
        #expect(calls.calls[0].arguments == Orca.worktreeListArguments)
        let create = calls.calls[1].arguments
        #expect(create.count == 8 && Array(create[0...4]) == ["terminal", "create", "--worktree", "path:" + root, "--command"] && Array(create[6...]) == ["--focus", "--json"])
        // The command is the plain path of a private script that goes to the conversation's own folder, which is deeper than the worktree.
        try expectResumeScript(create[5], runs: "cd -- \(Resume.quote(cwd)) && exec claude --resume '\(session)'")
        #expect(calls.calls[2].arguments == ["-b", "com.stablyai.orca"])
    }

    @Test func aFolderOutsideEveryWorktreeGoesToTerminalAndOpensNothingInOrca() throws {
        let cwd = try folder("loose")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree("/elsewhere/repo")])
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts), launcher: calls.launcher) == .terminal)
        #expect(calls.calls.map { $0.program + " " + ($0.arguments.first ?? "") } == ["orca worktree", "open -b"])
        #expect(calls.calls[1].arguments.dropLast() == ["-b", "com.apple.Terminal"])
    }

    @Test func orcaThatIsNotRunningIsNeverStartedOrAsked() throws {
        let cwd = try folder("repo")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree(cwd)])
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(running: [], scripts: scripts), launcher: calls.launcher) == .terminal)
        #expect(!calls.calls.contains { $0.program == "orca" } && !calls.calls.contains { $0.arguments.contains("com.stablyai.orca") })
        // Without its tool.
        let tool = Calls()
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts, orcaCLI: nil), launcher: tool.launcher) == .terminal)
        #expect(!tool.calls.contains { $0.program == "orca" })
    }

    @Test func aListingOrACreateThatFailsGoesToTerminalAndLeavesNoScript() throws {
        let cwd = try folder("repo")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let listing = Calls()
        listing.answers["orca:worktree"] = .some(nil)
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts), launcher: listing.launcher) == .terminal)
        #expect(!listing.calls.contains { $0.arguments.first == "terminal" })
        let garbage = Calls()
        garbage.answers["orca:worktree"] = "not json"
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts), launcher: garbage.launcher) == .terminal)
        #expect(!garbage.calls.contains { $0.arguments.first == "terminal" })

        let fresh = URL(fileURLWithPath: try folder("scripts"))
        let create = Calls()
        create.answers["orca:worktree"] = worktrees([worktree(cwd)])
        create.answers["orca:terminal"] = .some(nil)
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: fresh), launcher: create.launcher) == .terminal)
        #expect(!create.calls.contains { $0.arguments == ["-b", "com.stablyai.orca"] })
        // Orca's script is removed; the only one left is the one Terminal was given.
        let left = try FileManager.default.contentsOfDirectory(atPath: fresh.path).filter { $0.hasPrefix("nunsseop-resume-") }
        #expect(left.count == 1)
        let terminalScript = try #require(create.calls.last?.arguments.last)
        #expect(terminalScript.contains(left[0]))
    }

    @Test func aFolderOrSessionThatIsNotPlainIsNeverHandedToOrca() throws {
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree("/")])
        #expect(Resume.open(conversation("/does/not/exist"), in: .orca, setup: setup(scripts: scripts), launcher: calls.launcher) == nil)
        #expect(Resume.open(RecentConversation(kind: .claude, session: "bad;id", cwd: scripts.path, modified: .now), in: .orca,
                            setup: setup(scripts: scripts), launcher: calls.launcher) == nil)
        #expect(calls.calls.isEmpty)
    }

    @Test func theCreateArgumentsAreArgvWithTheWorktreeAsAPathSelector() {
        #expect(Orca.createArguments(worktree: "/Users/me/my repo", script: "/tmp/nunsseop-resume-A/resume.command")
                == ["terminal", "create", "--worktree", "path:/Users/me/my repo", "--command", "/tmp/nunsseop-resume-A/resume.command", "--focus", "--json"])
    }

    @Test func onlyATerminalOnScreenIsATabOpened() {
        #expect(Orca.isVisible(created: created(surface: "visible")))
        for output in [created(surface: "background"), created(surface: nil), created(surface: "Visible"), reply(["terminal": [String: Any]()]),
                       reply(["terminal": created(surface: "visible")]), reply(["surface": "visible"]),
                       reply(["terminal": ["surface": "visible"]], ok: false), #"{"terminal":{"surface":"visible"}}"#, "", "Terminal created", "[]"] {
            #expect(!Orca.isVisible(created: output), Comment(rawValue: output))
        }
    }

    @Test func aTerminalOrcaOnlyMadeInTheBackgroundIsNoSuccessAndLeavesNoOrcaScript() throws {
        // Exit code 0 with `surface: "background"`: the script ran in a process nobody sees, so the next terminal is asked.
        let cwd = try folder("repo")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree(cwd)])
        calls.answers["orca:terminal"] = created(surface: "background")
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: scripts), launcher: calls.launcher) == .terminal)
        #expect(!calls.calls.contains { $0.arguments == ["-b", "com.stablyai.orca"] })
        let left = try FileManager.default.contentsOfDirectory(atPath: scripts.path).filter { $0.hasPrefix("nunsseop-resume-") }
        #expect(left.count == 1)
        // A plain-text reply (an Orca that ignores --json) is no proof either.
        let plain = Calls()
        plain.answers["orca:worktree"] = worktrees([worktree(cwd)])
        plain.answers["orca:terminal"] = "Created terminal term_1"
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(scripts: URL(fileURLWithPath: try folder("scripts"))), launcher: plain.launcher) == .terminal)
    }

    @Test func orcaWithNoWindowIsNeverAskedToMakeATerminal() throws {
        // It stays running without a window on macOS, and would make the terminal as a hidden process.
        let cwd = try folder("repo")
        let scripts = URL(fileURLWithPath: try folder("scripts"))
        let calls = Calls()
        calls.answers["orca:worktree"] = worktrees([worktree(cwd)])
        calls.answers["orca:terminal"] = created(surface: "visible")
        #expect(Resume.open(conversation(cwd), in: .orca, setup: setup(window: false, scripts: scripts), launcher: calls.launcher) == .terminal)
        #expect(!calls.calls.contains { $0.program == "orca" } && !calls.calls.contains { $0.arguments.contains("com.stablyai.orca") })
    }
}
