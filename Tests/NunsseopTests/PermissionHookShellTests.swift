import CryptoKit
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

    /// - key: the permission key; nil leaves the file out.
    /// - keyFile: the key file's text, instead of `key`.
    /// - notifyToken: the notify token the home also holds, which the hook has nothing to do with.
    init(key: String? = String(repeating: "0123456789abcdef", count: 4), keyFile: String? = nil, mode: Mode = .fail,
         input: Data = PermissionTestServer.hookInput(), command: String = NotifyServer.permissionHookCommand,
         path: String? = nil, notifyToken: String? = String(repeating: "5e", count: 32)) throws {
        home = try ScratchHome(token: notifyToken, permissionKey: keyFile ?? key)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-stub-\(UUID().uuidString.prefix(8))")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let curl = bin.appendingPathComponent("curl")
        try StubTool.write("""
        #!/bin/sh
        for a; do printf '%s\\0' "$a"; done > "$D/args"
        echo $$ > "$D/pid"
        while [ $# -gt 0 ]; do
          case "$1" in
            -H) case "$2" in @*) cat "${2#@}" >> "$D/headers" ;; *) printf '%s\\n' "$2" >> "$D/headers" ;; esac; shift ;;
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
        """, to: curl)
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

    /// The header lines curl was told to send, `-H @file` read as curl reads it.
    var sentHeaders: String? { text("headers") }

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
    private let keys = [
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

    @Test func theShellsProofIsCryptoKitsForAnyKeyAndBody() async throws {
        for key in keys {
            for body in bodies {
                let hook = try StubbedHook(key: key, input: body)
                let sent = try #require(await hook.request(), "\(key.count)")
                #expect(sent.body == body)
                #expect(PermissionWire.isNonce(sent.nonce))
                #expect(sent.proof == PermissionWire.requestProof(key: key, nonce: sent.nonce, body: sent.body),
                        "key of \(key.count) bytes, body of \(body.count)")
                #expect(await hook.process.finish()?.stdout == "")
            }
        }
    }

    @Test func aKeyFileWithWhitespaceAroundItIsTheSameKey() async throws {
        let key = String(repeating: "0123456789abcdef", count: 4)
        let hook = try StubbedHook(keyFile: "  \(key)\r\n\n")
        let sent = try #require(await hook.request())
        #expect(sent.proof == PermissionWire.requestProof(key: key, nonce: sent.nonce, body: sent.body))
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
        #expect(sent.proof == PermissionWire.requestProof(key: String(repeating: "0123456789abcdef", count: 4),
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
        let key = String(repeating: "0123456789abcdef", count: 4)
        for answer in [PermissionAnswer.allow, .deny, .always] {
            let hook = try StubbedHook(key: key, mode: .answer)
            let sent = try #require(await hook.request())
            let text = try decision(answer)
            let proof = PermissionWire.responseProof(key: key, nonce: sent.nonce, decision: Data(text.utf8))
            try hook.answer("\(proof) \(text)")
            let result = try #require(await hook.process.finish())
            #expect(result.stdout == text, "\(answer)")
            #expect(result.status == 0)
        }
    }

    @Test func anAnswerThatIsNotProvenIsNotPrinted() async throws {
        let key = String(repeating: "0123456789abcdef", count: 4)
        let allow = try decision(.allow), deny = try decision(.deny)
        func response(_ nonce: String, of text: String = allow, key signing: String = key, said: String? = nil) -> String {
            "\(PermissionWire.responseProof(key: signing, nonce: nonce, decision: Data(text.utf8))) \(said ?? text)"
        }
        let others: [(String, (String) -> String)] = [
            ("another nonce", { _ in response(String(repeating: "ab", count: 16)) }),
            ("another decision", { response($0, of: deny, said: allow) }),
            ("the request's domain", { "\(PermissionWire.requestProof(key: key, nonce: $0, body: Data(allow.utf8))) \(allow)" }),
            ("another key", { response($0, key: key + "0") }),
            ("a decision cut short", { response($0, said: String(allow.dropLast())) }),
            ("a decision with more after a newline", { response($0, said: allow + "\nextra") }),
            ("no decision", { response($0, of: "", said: "") }),
            ("no proof", { _ in " " + allow }),
            ("no space", { _ in allow }),
            ("a proof alone", { PermissionWire.responseProof(key: key, nonce: $0, decision: Data(allow.utf8)) }),
            ("garbage", { _ in "HTTP/1.1 200 OK" }),
            ("nothing", { _ in "" }),
        ]
        for (name, make) in others {
            let hook = try StubbedHook(key: key, mode: .answer)
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
            ("no key file", { try StubbedHook(key: nil) }),
            ("an empty key file", { try StubbedHook(keyFile: "") }),
            ("a key too short to be ours", { try StubbedHook(keyFile: "short") }),
            ("no input", { try StubbedHook(input: Data()) }),
            ("an input over the cap", { try StubbedHook(input: Data(repeating: 0x61, count: PermissionGate.maxBodyBytes + 1)) }),
            ("no tools to compute with", { try StubbedHook(input: body, path: "/nonexistent") }),
        ]
        for (name, make) in cases {
            let hook = try make()
            let result = try #require(await hook.process.finish(), Comment(rawValue: name))
            #expect(result.stdout == "", Comment(rawValue: name))
            #expect(result.status == 0, Comment(rawValue: name))
            if ["no key file", "an empty key file", "a key too short to be ours", "no input", "an input over the cap",
                "no tools to compute with"].contains(name) {
                #expect(!hook.curlWasCalled, Comment(rawValue: name))
            }
        }
    }

    @Test func aServerThatIsNotThereCostsTheTerminalNothing() async throws {
        let holder = try NotifyServerListenTests.PortHolder()
        let port = holder.port
        holder.release()
        let home = try ScratchHome(permissionKey: String(repeating: "0123456789abcdef", count: 4))
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

    // MARK: The key stays out of arguments and off the wire

    @Test func theKeyIsInNoProcessArgumentsAndIsNeverSent() async throws {
        let key = String(repeating: "0123456789abcdef", count: 4)
        let hook = try StubbedHook(key: key, mode: .fail)
        let sent = try #require(await hook.request())
        #expect(await hook.process.finish()?.stdout == "")
        let wire = (hook.arguments ?? Data()) + sent.body
        #expect(!String(decoding: wire, as: UTF8.self).contains(key))
        #expect(!String(decoding: wire, as: UTF8.self).lowercased().contains("authorization"))
        #expect(String(decoding: hook.arguments ?? Data(), as: UTF8.self).contains(sent.proof))
    }

    /// Every program the hook starts is a link to this, which writes down its arguments and then runs the real one.
    @Test func noProgramTheHookStartsIsGivenTheKeyOrAnythingDerivedFromIt() async throws {
        let key = String(repeating: "0123456789abcdef", count: 4)
        let shims = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-shims-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shims) }
        // One program under each name the hook might run, each recording the name it was started by.
        for name in ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat", "sleep"] {
            try StubTool.write("""
            #!/bin/sh
            t=${0##*/}; t=${t%.body}
            printf '%s\\0' "$t" "$@" >> "$LOG"
            for d in /usr/bin /bin; do [ -x "$d/$t" ] && exec "$d/$t" "$@"; done
            exit 127
            """, to: shims.appendingPathComponent(name))
        }
        let log = shims.appendingPathComponent("argv.log")

        let holder = try NotifyServerListenTests.PortHolder()
        let port = holder.port
        holder.release()
        let notifyToken = String(repeating: "5e", count: 32)
        let home = try ScratchHome(token: notifyToken, permissionKey: key)
        let hook = try HookProcess(command: NotifyServer.permissionHookCommand(port: port), home: home.url,
                                   stdin: PermissionTestServer.hookInput(), path: shims.path, environment: ["LOG": log.path])
        _ = try #require(await hook.finish())

        let arguments = try Data(contentsOf: log)
        let text = String(decoding: arguments, as: UTF8.self)
        let programs = Set(text.components(separatedBy: "\0").filter { ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat"].contains($0) })
        // The log really saw the programs that handle the key and the request, so its silence about the key means something.
        #expect(programs.isSuperset(of: ["openssl", "curl", "tr", "od", "dd", "sed", "wc", "cat"]), "\(programs)")
        #expect(text.contains("X-Proof: "))
        let hex = Array(key.utf8).map { String(format: "%02x", $0) }.joined()
        let pads = Array(key.utf8).map { String(format: "%02x", $0 ^ 0x36) }.joined()
        for secret in [key, hex, pads, String(key.prefix(16)), String(key.suffix(16))] {
            #expect(!text.contains(secret), "\(secret.prefix(8))…")
        }
        // The notify token is not the hook's to read, so no program has it either.
        #expect(!text.contains(notifyToken))
    }

    /// A stranger who binds the port while Nunsseop is off gets every notice hook's headers, the notify token among them.
    /// The permission key is not in them, and nothing made from the token is the key, so no answer he makes is printed.
    @Test func aListenerThatLearnsTheNotifyTokenFromANoticeHookCannotProduceAnAnswerThePermissionHookPrints() async throws {
        let token = String(repeating: "5e", count: 32), key = String(repeating: "0123456789abcdef", count: 4)
        let notice = try StubbedHook(key: key, input: Data(#"{"message":"Needs you"}"#.utf8),
                                     command: NotifyServer.hookCommand(title: "Claude Code"), notifyToken: token)
        #expect(await notice.process.finish()?.status == 0)
        let received = try #require(notice.sentHeaders)
        #expect(received.contains("Authorization: Bearer \(token)"), "the listener learns the notify token")
        #expect(!received.contains(key))
        let learned = try #require(received.components(separatedBy: "\n").first { $0.hasPrefix("Authorization: Bearer ") }
            .map { String($0.dropFirst("Authorization: Bearer ".count)) })

        let allow = try decision(.allow)
        let sha = SHA256.hash(data: Data(learned.utf8))
        let guesses = [learned, learned.uppercased(), Data(learned.utf8).map { String(format: "%02x", $0) }.joined(),
                       sha.map { String(format: "%02x", $0) }.joined(), learned + learned, String(learned.prefix(32))]
        for guess in guesses {
            let hook = try StubbedHook(key: key, mode: .answer, notifyToken: token)
            let sent = try #require(await hook.request())
            #expect(sent.proof != PermissionWire.requestProof(key: guess, nonce: sent.nonce, body: sent.body),
                    "the hook proved itself with something made from the token")
            let proof = PermissionWire.responseProof(key: guess, nonce: sent.nonce, decision: Data(allow.utf8))
            try hook.answer("\(proof) \(allow)")
            let result = try #require(await hook.process.finish())
            #expect(result.stdout == "" && result.status == 0, "an answer made from \(guess.prefix(8))… was printed")
        }

        // The control: the same exchange with the key is printed.
        let hook = try StubbedHook(key: key, mode: .answer, notifyToken: token)
        let sent = try #require(await hook.request())
        try hook.answer("\(PermissionWire.responseProof(key: key, nonce: sent.nonce, decision: Data(allow.utf8))) \(allow)")
        #expect(await hook.process.finish()?.stdout == allow)
    }

    @Test func theCommandNamesTheKeyFileAndNeitherTheNotifyTokenNorItsHeaderFile() {
        let command = NotifyServer.permissionHookCommand
        #expect(command.contains("Application Support/Nunsseop/permission-key"))
        #expect(!command.contains("notify-token") && !command.contains("notify-auth"))
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

    @Test func theCommandReadsTheKeyOnlyByRedirectionAndSendsNoBearer() {
        let command = NotifyServer.permissionHookCommand
        #expect(!command.contains("Bearer") && !command.lowercased().contains("authorization"))
        #expect(!command.contains("cat \"$t\"") && !command.contains("$(<"))
        var searchRange = command.startIndex..<command.endIndex
        var uses = 0
        while let range = command.range(of: "\"$t\"", range: searchRange) {
            #expect(command[..<range.lowerBound].hasSuffix("< "), "a use of the key file that isn't a redirection")
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
