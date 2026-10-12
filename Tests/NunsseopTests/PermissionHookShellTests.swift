import Foundation
import Testing
@testable import Nunsseop

/// The PermissionRequest hook run by a real `/bin/sh`, with a stand-in `curl` that records what it was asked and answers
/// as a test says, so what the shell computes can be compared with CryptoKit's.
private final class StubbedHook {
    enum Mode: String { case fail, silent, answer }

    let dir: URL
    let home: ScratchHome
    let process: HookProcess

    /// - tokenFile: the token file's text; nil leaves it out.
    init(token: String? = String(repeating: "0123456789abcdef", count: 4), tokenFile: String? = nil, mode: Mode = .fail,
         input: Data = PermissionTestServer.hookInput(), command: String = NotifyServer.permissionHookCommand,
         path: String? = nil) throws {
        home = try ScratchHome(token: tokenFile ?? token)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-stub-\(UUID().uuidString.prefix(8))")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let curl = bin.appendingPathComponent("curl")
        try """
        #!/bin/sh
        for a; do printf '%s\\0' "$a"; done > "$D/args"
        echo $$ > "$D/pid"
        while [ $# -gt 0 ]; do
          case "$1" in
            -H) printf '%s\\n' "$2" >> "$D/headers"; shift ;;
          esac
          shift
        done
        cat > "$D/body"
        : > "$D/read"
        case "$MODE" in
          fail) exit 7 ;;
          answer) while [ ! -f "$D/response" ]; do sleep 0.02; done; cat "$D/response" ;;
        esac
        exit 0
        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        process = try HookProcess(command: command, home: home.url, stdin: input,
                                  path: path ?? "\(bin.path):/usr/bin:/bin", environment: ["D": dir.path, "MODE": mode.rawValue])
    }

    deinit {
        if let pid = curlPID { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    var header: (nonce: String, proof: String)? {
        let lines = text("headers")?.components(separatedBy: "\n") ?? []
        func value(_ name: String) -> String? { lines.first { $0.hasPrefix(name + ": ") }.map { String($0.dropFirst(name.count + 2)) } }
        guard let nonce = value("X-Nonce"), let proof = value("X-Proof") else { return nil }
        return (nonce, proof)
    }

    var body: Data? { try? Data(contentsOf: dir.appendingPathComponent("body")) }
    var arguments: Data? { try? Data(contentsOf: dir.appendingPathComponent("args")) }
    var curlPID: pid_t? { text("pid").flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var curlWasCalled: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("args").path) }

    func answer(_ text: String) throws {
        let temporary = dir.appendingPathComponent("response.tmp")
        try Data(text.utf8).write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: dir.appendingPathComponent("response"))
    }

    /// Waits until the hook has called curl, then returns what it sent.
    func request() async -> (nonce: String, proof: String, body: Data)? {
        await eventually { FileManager.default.fileExists(atPath: dir.appendingPathComponent("read").path) && curlPID != nil }
        guard let header, let body else { return nil }
        return (header.nonce, header.proof, body)
    }
}

@MainActor
struct PermissionHookShellTests {
    private let tokens = [
        // 0x36 is the HMAC inner pad, so each of these characters makes a NUL byte in the padded key.
        "6666666666666666666666666666666666666666666666666666666666666666",
        String(repeating: "0123456789abcdef", count: 4),
        String(repeating: "b", count: 32),
        String(String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", count: 2).prefix(100)),
        // 64 bytes is the HMAC block size, and 65 the first that is hashed.
        String(repeating: "q", count: 64), String(repeating: "q", count: 65),
    ]

    private let bodies: [Data] = [
        PermissionTestServer.hookInput(),
        PermissionTestServer.hookInput(input: ["command": "echo \"한글\" 'x' $HOME `id` 100% \\ \\n \\\\ ; rm -rf *"]),
        PermissionTestServer.hookInput(tool: "Write", input: ["file_path": "/a/b", "content": String(repeating: "line\n", count: 4000)],
                                       suggestions: [PermissionTestServer.addRules]),
    ]

    // MARK: Request proof

    @Test func theShellsProofIsCryptoKitsForAnyTokenAndBody() async throws {
        for token in tokens {
            for body in bodies {
                let hook = try StubbedHook(token: token, input: body)
                let sent = try #require(await hook.request(), "\(token.count)")
                #expect(sent.body == body)
                #expect(PermissionWire.isNonce(sent.nonce))
                #expect(sent.proof == PermissionWire.requestProof(token: token, nonce: sent.nonce, body: sent.body),
                        "token of \(token.count) bytes, body of \(body.count)")
                #expect(await hook.process.finish()?.stdout == "")
            }
        }
    }

    @Test func aTokenFileWithWhitespaceAroundItIsTheSameKey() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let hook = try StubbedHook(tokenFile: "  \(token)\r\n\n")
        let sent = try #require(await hook.request())
        #expect(sent.proof == PermissionWire.requestProof(token: token, nonce: sent.nonce, body: sent.body))
    }

    @Test func eachRequestHasANonceOfItsOwn() async throws {
        let first = try #require(await StubbedHook().request()), second = try #require(await StubbedHook().request())
        #expect(first.nonce != second.nonce && first.proof != second.proof)
    }

    @Test func aTrailingNewlineOnTheInputIsDroppedFromBothTheBodyAndTheProof() async throws {
        let body = PermissionTestServer.hookInput()
        let hook = try StubbedHook(input: body + Data("\n\n".utf8))
        let sent = try #require(await hook.request())
        #expect(sent.body == body)
        #expect(sent.proof == PermissionWire.requestProof(token: String(repeating: "0123456789abcdef", count: 4),
                                                           nonce: sent.nonce, body: body))
    }

    // MARK: Answers

    private func decision(_ answer: PermissionAnswer) throws -> String {
        let suggestion: [String: Any]? = [
            "type": "addRules", "behavior": "allow", "destination": "localSettings",
            "rules": [["toolName": "Bash", "ruleContent": "echo \"a\\b\" 100% $HOME `x` 한글"]],
        ]
        return String(decoding: try #require(PermissionWire.decision(answer, suggestion: suggestion)), as: UTF8.self)
    }

    @Test func anAnswerWithItsProofIsPrintedByteForByte() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        for answer in [PermissionAnswer.allow, .deny, .always] {
            let hook = try StubbedHook(token: token, mode: .answer)
            let sent = try #require(await hook.request())
            let text = try decision(answer)
            let proof = PermissionWire.responseProof(token: token, nonce: sent.nonce, decision: Data(text.utf8))
            try hook.answer("\(proof) \(text)")
            let result = try #require(await hook.process.finish())
            #expect(result.stdout == text, "\(answer)")
            #expect(result.status == 0)
        }
    }

    @Test func anAnswerThatIsNotProvenIsNotPrinted() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let allow = try decision(.allow), deny = try decision(.deny)
        func response(_ nonce: String, of text: String = allow, token key: String = token, said: String? = nil) -> String {
            "\(PermissionWire.responseProof(token: key, nonce: nonce, decision: Data(text.utf8))) \(said ?? text)"
        }
        let others: [(String, (String) -> String)] = [
            ("another nonce", { _ in response(String(repeating: "ab", count: 16)) }),
            ("another decision", { response($0, of: deny, said: allow) }),
            ("the request's domain", { "\(PermissionWire.requestProof(token: token, nonce: $0, body: Data(allow.utf8))) \(allow)" }),
            ("another token", { response($0, token: token + "0") }),
            ("a decision cut short", { response($0, said: String(allow.dropLast())) }),
            ("a decision with more after a newline", { response($0, said: allow + "\nextra") }),
            ("no decision", { response($0, of: "", said: "") }),
            ("no proof", { _ in " " + allow }),
            ("no space", { _ in allow }),
            ("a proof alone", { PermissionWire.responseProof(token: token, nonce: $0, decision: Data(allow.utf8)) }),
            ("garbage", { _ in "HTTP/1.1 200 OK" }),
            ("nothing", { _ in "" }),
        ]
        for (name, make) in others {
            let hook = try StubbedHook(token: token, mode: .answer)
            let sent = try #require(await hook.request())
            try hook.answer(make(sent.nonce))
            let result = try #require(await hook.process.finish())
            #expect(result.stdout == "", "\(name)")
            #expect(result.status == 0, "\(name)")
        }
    }

    // MARK: Failures print nothing

    @Test func everyFailureEndsInNothingPrintedAndAnExitOfZero() async throws {
        let body = PermissionTestServer.hookInput()
        let cases: [(String, () throws -> StubbedHook)] = [
            ("curl fails", { try StubbedHook(mode: .fail) }),
            ("curl says nothing", { try StubbedHook(mode: .silent) }),
            ("no token file", { try StubbedHook(token: nil) }),
            ("an empty token file", { try StubbedHook(tokenFile: "") }),
            ("a token too short to be ours", { try StubbedHook(tokenFile: "short") }),
            ("no input", { try StubbedHook(input: Data()) }),
            ("an input over the cap", { try StubbedHook(input: Data(repeating: 0x61, count: PermissionGate.maxBodyBytes + 1)) }),
            ("no tools to compute with", { try StubbedHook(input: body, path: "/nonexistent") }),
        ]
        for (name, make) in cases {
            let hook = try make()
            let result = try #require(await hook.process.finish(), Comment(rawValue: name))
            #expect(result.stdout == "", Comment(rawValue: name))
            #expect(result.status == 0, Comment(rawValue: name))
            if ["no token file", "an empty token file", "a token too short to be ours", "no input", "an input over the cap",
                "no tools to compute with"].contains(name) {
                #expect(!hook.curlWasCalled, Comment(rawValue: name))
            }
        }
    }

    @Test func aServerThatIsNotThereCostsTheTerminalNothing() async throws {
        let holder = try NotifyServerListenTests.PortHolder()
        let port = holder.port
        holder.release()
        let home = try ScratchHome(token: String(repeating: "0123456789abcdef", count: 4))
        let hook = try HookProcess(command: NotifyServer.permissionHookCommand(port: port), home: home.url,
                                   stdin: PermissionTestServer.hookInput())
        let result = try #require(await hook.finish())
        #expect(result.stdout == "" && result.status == 0)
        // A hook that waited for the missing server would take curl's whole 590 s; a loaded machine is slow, never that slow. It is the
        // hook's own run that is timed, from its start to its exit: the wall clock of this task also counts the time the task waited to
        // be resumed, which on a runner busy with the other tests' synchronous work was over a minute for a hook that took a second.
        await eventually { hook.lifetime != nil }
        let lifetime = try #require(hook.lifetime)
        #expect(lifetime < 15, "the hook ran \(lifetime) s")
    }

    @Test func theConnectTimeoutIsOneSecondAndTheWholeRequestIsBoundedBelowTheHooksOwn() {
        let command = NotifyServer.permissionHookCommand
        #expect(command.contains("--connect-timeout 1 ") && !command.contains("--connect-timeout 10"))
        #expect(command.contains("curl -s -m 590 "))
    }

    // MARK: The token stays out of arguments and off the wire

    @Test func theTokenIsInNoProcessArgumentsAndIsNeverSent() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let hook = try StubbedHook(token: token, mode: .fail)
        let sent = try #require(await hook.request())
        #expect(await hook.process.finish()?.stdout == "")
        let wire = (hook.arguments ?? Data()) + sent.body
        #expect(!String(decoding: wire, as: UTF8.self).contains(token))
        #expect(!String(decoding: wire, as: UTF8.self).lowercased().contains("authorization"))
        #expect(String(decoding: hook.arguments ?? Data(), as: UTF8.self).contains(sent.proof))
    }

    /// Every program the hook starts is a link to this, which writes down its arguments and then runs the real one.
    @Test func noProgramTheHookStartsIsGivenTheTokenOrAnythingDerivedFromIt() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let shims = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-shims-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shims) }
        let shim = shims.appendingPathComponent("shim")
        try """
        #!/bin/sh
        t=${0##*/}
        printf '%s\\0' "$t" "$@" >> "$LOG"
        for d in /usr/bin /bin; do [ -x "$d/$t" ] && exec "$d/$t" "$@"; done
        exit 127
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        for name in ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat", "sleep"] {
            try FileManager.default.createSymbolicLink(at: shims.appendingPathComponent(name), withDestinationURL: shim)
        }
        let log = shims.appendingPathComponent("argv.log")

        let holder = try NotifyServerListenTests.PortHolder()
        let port = holder.port
        holder.release()
        let home = try ScratchHome(token: token)
        let hook = try HookProcess(command: NotifyServer.permissionHookCommand(port: port), home: home.url,
                                   stdin: PermissionTestServer.hookInput(), path: shims.path, environment: ["LOG": log.path])
        _ = try #require(await hook.finish())

        let arguments = try Data(contentsOf: log)
        let text = String(decoding: arguments, as: UTF8.self)
        let programs = Set(text.components(separatedBy: "\0").filter { ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat"].contains($0) })
        // The log really saw the programs that handle the key and the request, so its silence about the token means something.
        #expect(programs.isSuperset(of: ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat"]), "\(programs)")
        #expect(text.contains("X-Proof: "))
        let hex = Array(token.utf8).map { String(format: "%02x", $0) }.joined()
        let pads = Array(token.utf8).map { String(format: "%02x", $0 ^ 0x36) }.joined()
        for secret in [token, hex, pads, String(token.prefix(16)), String(token.suffix(16))] {
            #expect(!text.contains(secret), "\(secret.prefix(8))…")
        }
    }

    @Test func curlGivesUpAfterTheServerLetsGoAndBeforeClaudeCodeStopsTheHook() throws {
        let command = NotifyServer.permissionHookCommand
        let afterFlag = try #require(command.components(separatedBy: " -m ").dropFirst().first)
        let seconds = try #require(Double(afterFlag.prefix { $0.isNumber }))
        #expect(seconds > PermissionGate.holdSeconds, "curl would hang up before the server answers a prompt nobody touched")
        #expect(seconds < Double(JSONHook.permissionTimeout), "Claude Code would stop the hook first")
        #expect(command.components(separatedBy: " -m ").count == 2)
    }

    @Test func theCommandKeepsTheAnswerInAVariableNotInAFile() {
        let command = NotifyServer.permissionHookCommand
        #expect(!command.contains("mktemp") && !command.contains("TMPDIR") && !command.contains("/tmp"))
        #expect(!command.contains(" -o ") && !command.contains(" > "))
    }

    @Test func theCommandReadsTheTokenOnlyByRedirectionAndSendsNoBearer() {
        let command = NotifyServer.permissionHookCommand
        #expect(!command.contains("Bearer") && !command.lowercased().contains("authorization"))
        #expect(!command.contains("cat \"$t\"") && !command.contains("$(<"))
        var searchRange = command.startIndex..<command.endIndex
        var uses = 0
        while let range = command.range(of: "\"$t\"", range: searchRange) {
            #expect(command[..<range.lowerBound].hasSuffix("< "), "a use of the token file that isn't a redirection")
            uses += 1
            searchRange = range.upperBound..<command.endIndex
        }
        #expect(uses == 2)
        #expect(command.contains("--connect-timeout 1") && command.contains("127.0.0.1:47750/permission"))
    }

    // MARK: Killed with its terminal's answer

    @Test func whenClaudeCodeEndsTheHookItsRequestEndsToo() async throws {
        let hook = try StubbedHook(mode: .answer)
        _ = try #require(await hook.request())
        let pid = try #require(hook.curlPID)
        #expect(kill(pid, 0) == 0)
        hook.process.process.terminate()
        let result = await hook.process.finish()
        #expect(result?.stdout == "")
        await eventually { kill(pid, 0) != 0 }
        #expect(kill(pid, 0) != 0, "curl was left waiting")
    }
}
