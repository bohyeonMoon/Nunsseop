import CryptoKit
import Foundation
import Testing
@testable import Nunsseop

struct PermissionWireTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theProofIsAnHMACOverTheDomainTheNonceAndTheBodysDigest() {
        let token = String(repeating: "ab", count: 32), nonce = String(repeating: "0f", count: 16)
        let body = Data("{\"tool_name\":\"Bash\"}".utf8)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("nunsseop-permission-request\n\(nonce)\n\(digest)".utf8)
        let expected = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(PermissionWire.requestProof(token: token, nonce: nonce, body: body) == expected)
        #expect(expected.count == 64)
    }

    @Test func requestAndResponseProofsAreBoundToTheirDomainAndNonce() {
        let token = String(repeating: "cd", count: 32), nonce = String(repeating: "1a", count: 16)
        let other = String(repeating: "2b", count: 16)
        let bytes = Data("same bytes".utf8)
        let request = PermissionWire.requestProof(token: token, nonce: nonce, body: bytes)
        let response = PermissionWire.responseProof(token: token, nonce: nonce, decision: bytes)
        #expect(request != response)
        #expect(response != PermissionWire.responseProof(token: token, nonce: other, decision: bytes))
        #expect(response != PermissionWire.responseProof(token: token + "0", nonce: nonce, decision: bytes))
        #expect(response != PermissionWire.responseProof(token: token, nonce: nonce, decision: bytes + [0x20]))
    }

    @Test func aNonceIsSixteenBytesOfLowercaseHex() {
        #expect(PermissionWire.isNonce(String(repeating: "0a", count: 16)))
        for bad in ["", String(repeating: "0a", count: 15), String(repeating: "0a", count: 17), String(repeating: "0A", count: 16),
                    String(repeating: "g0", count: 16), String(repeating: "0a", count: 15) + "0\n"] {
            #expect(!PermissionWire.isNonce(bad), "\(bad)")
        }
    }

    @Test func theDecisionsAreExactlyWhatClaudeCodeReads() throws {
        let prefix = #"{"hookSpecificOutput":{"decision":{"#
        let suffix = #"},"hookEventName":"PermissionRequest"}}"#
        #expect(String(decoding: try #require(PermissionWire.decision(.allow, suggestion: nil)), as: UTF8.self)
                == prefix + #""behavior":"allow""# + suffix)
        #expect(String(decoding: try #require(PermissionWire.decision(.deny, suggestion: nil)), as: UTF8.self)
                == prefix + #""behavior":"deny","message":"Denied in Nunsseop""# + suffix)
    }

    @Test func alwaysAllowEchoesTheOneSuggestionAndNeedsOne() throws {
        let data = try #require(PermissionWire.decision(.always, suggestion: PermissionTestServer.addRules))
        let decision = try #require((try json(data)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(updated.count == 1)
        #expect(NSDictionary(dictionary: updated[0]).isEqual(to: PermissionTestServer.addRules))
        #expect(!String(decoding: data, as: UTF8.self).contains("setMode"))
        #expect(PermissionWire.decision(.always, suggestion: nil) == nil)
    }

    @Test func aDecisionIsOneLineEvenForAnAwkwardRule() throws {
        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                   "rules": [["toolName": "Bash", "ruleContent": "echo \"a\\b\"\n100% $HOME `x`"]]]
        let data = try #require(PermissionWire.decision(.always, suggestion: rule))
        #expect(!data.contains(0x0a))
    }
}

struct PermissionPromptParseTests {
    private func parse(_ tool: String, _ input: [String: Any], cwd: String = "/Users/me/proj",
                       suggestions: [[String: Any]]? = nil) -> PermissionPrompt.Parsed? {
        PermissionPrompt.parse(PermissionTestServer.hookInput(tool: tool, input: input, cwd: cwd, suggestions: suggestions))
    }

    private func addRules(_ rules: [[String: Any]], destination: String? = "localSettings") -> [String: Any] {
        var suggestion: [String: Any] = ["type": "addRules", "behavior": "allow", "rules": rules]
        suggestion["destination"] = destination
        return suggestion
    }

    @Test func aCommandIsShownWithItsFolderAndTheRuleItWouldAdd() throws {
        let parsed = try #require(parse("Bash", ["command": "npm run build"], suggestions: [PermissionTestServer.addRules]))
        #expect(parsed.prompt.title == "Run a command")
        #expect(parsed.prompt.detail == "npm run build")
        #expect(parsed.prompt.folder == "proj")
        #expect(parsed.prompt.grant == PermissionPrompt.Grant(rules: ["Bash(npm run *)"], place: .localSettings))
        #expect(parsed.prompt.symbol == "terminal")
        #expect(parsed.suggestion != nil)
    }

    @Test func fileAndWebToolsSayWhatTheyDoInPlainWords() throws {
        let cases: [(String, [String: Any], String, String)] = [
            ("Edit", ["file_path": "/a/b.swift"], "Edit a file", "/a/b.swift"),
            ("MultiEdit", ["file_path": "/a/c.swift"], "Edit a file", "/a/c.swift"),
            ("Write", ["file_path": "/a/new.txt"], "Write a file", "/a/new.txt"),
            ("NotebookEdit", ["notebook_path": "/a/n.ipynb"], "Edit a notebook", "/a/n.ipynb"),
            ("Read", ["file_path": "/etc/hosts"], "Read a file", "/etc/hosts"),
            ("WebFetch", ["url": "https://example.com/x"], "Fetch a web page", "https://example.com/x"),
            ("WebSearch", ["query": "swift nio"], "Search the web", "swift nio"),
        ]
        for (tool, input, title, detail) in cases {
            let parsed = try #require(parse(tool, input), "\(tool)")
            #expect(parsed.prompt.title == title && parsed.prompt.detail == detail && parsed.prompt.secondary.isEmpty, "\(tool)")
        }
    }

    // MARK: Known tools hide nothing

    @Test func aCommandShowsItsDescriptionAndEveryOtherFieldItWasGiven() throws {
        let prompt = try #require(parse("Bash", ["command": "make", "description": "Build it", "timeout": 120000, "cwd": "/tmp"])).prompt
        #expect(prompt.detail == "make" && prompt.flags.isEmpty)
        #expect(prompt.secondary == "Build it\ncwd: /tmp\ntimeout: 120000")
        #expect(prompt.scrollText == "make\nBuild it\ncwd: /tmp\ntimeout: 120000")
        let plain = try #require(parse("Bash", ["command": "make"])).prompt
        #expect(plain.secondary.isEmpty && plain.scrollText == "make")
    }

    @Test func aCommandWithTheSandboxOffOrInTheBackgroundSaysSoAboveIt() throws {
        let both = try #require(parse("Bash", ["command": "curl x", "dangerouslyDisableSandbox": true, "run_in_background": true])).prompt
        #expect(both.flags == [.init(text: "Sandbox off", warns: true), .init(text: "Runs in the background", warns: false)])
        #expect(both.scrollText == "Sandbox off\nRuns in the background\ncurl x")
        #expect(both.secondary.isEmpty, "the flags are not listed twice")
        let sandbox = try #require(parse("Bash", ["command": "x", "dangerouslyDisableSandbox": true])).prompt
        #expect(sandbox.flags == [.init(text: "Sandbox off", warns: true)])
        let background = try #require(parse("Bash", ["command": "x", "run_in_background": true])).prompt
        #expect(background.flags == [.init(text: "Runs in the background", warns: false)])
        // Anything but a real true is listed as it is, since the tool may read a string or a number as true.
        for value: Any in [false, "true", 1, "yes", NSNull()] {
            let prompt = try #require(parse("Bash", ["command": "x", "dangerouslyDisableSandbox": value])).prompt
            #expect(prompt.flags.isEmpty && prompt.secondary.hasPrefix("dangerouslyDisableSandbox: "), "\(value)")
        }
    }

    @Test func aFileEditShowsThePathAndBothSidesOfTheChange() throws {
        let edit = try #require(parse("Edit", ["file_path": "/a/b.swift", "old_string": "let a = 1", "new_string": "let a = 2\nlet b = 3",
                                                "replace_all": true])).prompt
        #expect(edit.title == "Edit a file")
        #expect(edit.detail == "/a/b.swift\n\nold_string:\nlet a = 1\n\nnew_string:\nlet a = 2\nlet b = 3")
        #expect(edit.secondary == "replace_all: true")
        // Deleting text is an edit with nothing new in it, and is shown as one.
        let deletion = try #require(parse("Edit", ["file_path": "/a", "old_string": "x", "new_string": ""])).prompt
        #expect(deletion.detail == "/a\n\nold_string:\nx\n\nnew_string:\n")
    }

    @Test func aMultiEditShowsEveryEdit() throws {
        let edits: [[String: Any]] = [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d", "replace_all": true]]
        let prompt = try #require(parse("MultiEdit", ["file_path": "/a/b.swift", "edits": edits])).prompt
        #expect(prompt.detail == "/a/b.swift\n\nedit 1 of 2:\nold_string:\na\nnew_string:\nb\n\nedit 2 of 2:\nold_string:\nc\nnew_string:\nd\nreplace_all: true")
        #expect(prompt.secondary.isEmpty)
        // Edits that are not a list of objects are listed as they came.
        let odd = try #require(parse("MultiEdit", ["file_path": "/a", "edits": ["x", 3]])).prompt
        #expect(odd.detail == "/a" && odd.secondary == #"edits: ["x",3]"#)
    }

    @Test func aWriteShowsThePathAndWhatGoesInTheFile() throws {
        let prompt = try #require(parse("Write", ["file_path": "/a/new.txt", "content": "line 1\nline 2"])).prompt
        #expect(prompt.title == "Write a file")
        #expect(prompt.detail == "/a/new.txt\n\ncontent:\nline 1\nline 2" && prompt.secondary.isEmpty)
        let hidden = try #require(parse("Write", ["file_path": "/a", "content": "x\u{202E}y"])).prompt
        #expect(hidden.detail == "/a\n\ncontent:\nx⟨U+202E⟩y")
    }

    @Test func aNotebookEditShowsThePathTheNewSourceAndTheCell() throws {
        let prompt = try #require(parse("NotebookEdit", ["notebook_path": "/a/n.ipynb", "new_source": "print(1)", "cell_id": "c3",
                                                          "edit_mode": "replace", "cell_type": "code"])).prompt
        #expect(prompt.detail == "/a/n.ipynb\n\nnew_source:\nprint(1)")
        #expect(prompt.secondary == "cell_id: c3\ncell_type: code\nedit_mode: replace")
    }

    @Test func anyUnexpectedFieldOfAKnownToolIsListedEscaped() throws {
        let cases: [(String, [String: Any], String)] = [
            ("Bash", ["command": "ls", "extra": "a\u{202E}b"], "extra: a⟨U+202E⟩b"),
            ("Edit", ["file_path": "/a", "old_string": "x", "new_string": "y", "hidden": ["k": 1]], #"hidden: {"k":1}"#),
            ("Write", ["file_path": "/a", "content": "x", "mode": "0777"], "mode: 0777"),
            ("NotebookEdit", ["notebook_path": "/a", "new_source": "x", "n": 2], "n: 2"),
            ("Read", ["file_path": "/a", "offset": 10, "limit": 5], "limit: 5\noffset: 10"),
            ("WebFetch", ["url": "https://x.y", "prompt": "Summarize it"], "prompt: Summarize it"),
            ("WebSearch", ["query": "q", "allowed_domains": ["a.com"]], #"allowed_domains: ["a.com"]"#),
        ]
        for (tool, input, secondary) in cases {
            #expect(try #require(parse(tool, input), "\(tool)").prompt.secondary == secondary, "\(tool)")
        }
        // A field's name is escaped like its value.
        #expect(try #require(parse("Bash", ["command": "ls", "k\u{200B}ey": 1])).prompt.secondary == "k⟨U+200B⟩ey: 1")
    }

    @Test func whatIsShownAcrossAllItsPartsCountsAgainstTheLimit() {
        let half = String(repeating: "a", count: PermissionPrompt.detailLimit / 2)
        #expect(parse("Write", ["file_path": "/a", "content": half]) != nil)
        #expect(parse("Write", ["file_path": "/a", "content": half + half]) == nil)
        #expect(parse("Bash", ["command": "ls", "description": String(repeating: "d", count: PermissionPrompt.detailLimit)]) == nil)
        #expect(parse("Edit", ["file_path": "/a", "old_string": half, "new_string": half]) == nil)
    }

    // MARK: Tools without a plain description

    @Test func anyOtherToolShowsItsOwnNameAndAllOfItsInput() throws {
        let parsed = try #require(parse("mcp__github__create_issue", ["title": "Bug", "labels": ["a", "b"]]))
        #expect(parsed.prompt.title == "mcp__github__create_issue")
        #expect(parsed.prompt.detail == "{\n  \"labels\" : [\n    \"a\",\n    \"b\"\n  ],\n  \"title\" : \"Bug\"\n}")
        for tool in ["Task", "Skill", "TodoWrite"] {
            let prompt = try #require(parse(tool, ["description": "run /deploy", "n": 1])).prompt
            #expect(prompt.title == tool, "\(tool)")
            #expect(prompt.detail.contains(#""description" : "run /deploy""#) && prompt.detail.contains(#""n" : 1"#), "\(tool)")
        }
        #expect(try #require(parse("mcp__a__b", [:])).prompt.detail.isEmpty)
    }

    @Test func aKnownToolWhoseFieldIsNotTheTextItShouldBeShowsEverythingInstead() throws {
        for input: [String: Any] in [["command": 7, "timeout": 5], ["cmd": "ls"], ["command": ""]] {
            let prompt = try #require(parse("Bash", input)).prompt
            #expect(prompt.title == "Bash" && prompt.symbol == "puzzlepiece.extension")
            #expect(prompt.detail.contains(input.keys.sorted().first!))
        }
    }

    @Test func aToolNameIsEscapedLikeTheRestAndNotAcceptedWhenTooLongToShow() throws {
        let prompt = try #require(parse("Task\u{202E}x", [:])).prompt
        #expect(prompt.title == "Task⟨U+202E⟩x")
        #expect(parse(String(repeating: "t", count: PermissionPrompt.titleLimit), [:]) != nil)
        #expect(parse(String(repeating: "t", count: PermissionPrompt.titleLimit + 1), [:]) == nil)
    }

    @Test func questionsPlansAndNonsenseAreLeftToTheTerminal() {
        #expect(parse("AskUserQuestion", ["questions": []]) == nil)
        #expect(parse("ExitPlanMode", ["plan": "x"]) == nil)
        #expect(PermissionPrompt.parse(Data("not json".utf8)) == nil)
        #expect(PermissionPrompt.parse(Data()) == nil)
        let other = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "tool_name": "Bash"])
        #expect(PermissionPrompt.parse(other) == nil)
        let nameless = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest"])
        #expect(PermissionPrompt.parse(nameless) == nil)
    }

    // MARK: Lines and invisible characters

    @Test func lineBreaksStayLineBreaksAndNothingIsJoined() throws {
        let command = "echo safe\n\n\nrm -rf ~\r\nls"
        let prompt = try #require(parse("Bash", ["command": command])).prompt
        #expect(prompt.detail == "echo safe\n\n\nrm -rf ~\nls")
        #expect(prompt.detail.components(separatedBy: "\n").count == 5)
        #expect(PermissionText.escape("a\nb", multiline: false) == "a⟨U+000A⟩b")
    }

    @Test func controlZeroWidthAndDirectionCharactersAreShownNotRemoved() {
        #expect(PermissionText.escape("rm\u{202E} -rf\u{200B} /", multiline: true) == "rm⟨U+202E⟩ -rf⟨U+200B⟩ /")
        let invisible: [UInt32] = Array(0x200B...0x200F) + Array(0x202A...0x202E) + Array(0x2066...0x2069)
            + [0xFEFF, 0x00AD, 0x2060, 0xE0041, 0x0000, 0x0007, 0x001B, 0x007F, 0x0085, 0x2028, 0x2029, 0x00A0, 0x3000, 0x2003]
        for value in invisible {
            let scalar = Character(Unicode.Scalar(value)!)
            #expect(PermissionText.escape("a\(scalar)b", multiline: true) == "a" + String(format: "⟨U+%04X⟩", value) + "b",
                    "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect(PermissionText.escape("a\tb\rc", multiline: true) == "a⟨U+0009⟩b⟨U+000D⟩c")
        // A written-out escape can't be told from a real one, so the brackets are escaped too.
        #expect(PermissionText.escape("⟨U+202E⟩", multiline: true) == "⟨U+27E8⟩U+202E⟨U+27E9⟩")
        for plain in ["echo \"한글 😀 é\" 'x' $HOME `id` 100% \\n", "👨‍👩‍👧"] where plain != "👨‍👩‍👧" {
            #expect(PermissionText.escape(plain, multiline: true) == plain)
        }
    }

    @Test func scalarsThatDrawNothingAreShownEvenWhenNotFormatCharacters() {
        func hex(_ value: UInt32) -> String { String(format: "⟨U+%04X⟩", value) }
        var blanks: [UInt32] = [0x2800, 0x3164, 0xFFA0, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x034F, 0x061C, 0x180E, 0x1680, 0x202F, 0x205F,
                                0xFFFC, 0xFFF9, 0xE000, 0xF8FF, 0x0378, 0xE0001, 0x1D173, 0x2063, 0x2064]
        blanks += Array(0xFE00...0xFE0F) + Array(0xE0100...0xE01EF) + Array(0x180B...0x180F) + Array(0x2000...0x200A)
        for value in blanks {
            let scalar = Character(Unicode.Scalar(value)!)
            #expect(PermissionText.escape("a\(scalar)b", multiline: true) == "a" + hex(value) + "b", "U+\(String(value, radix: 16, uppercase: true))")
        }
        // Every default-ignorable scalar of the table, whatever the list above says.
        var checked = 0
        for value in UInt32(0)...0xE01EF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isDefaultIgnorableCodePoint else { continue }
            #expect(PermissionText.escape("a\(scalar)b", multiline: true) == "a" + hex(value) + "b", "U+\(String(value, radix: 16, uppercase: true))")
            checked += 1
        }
        #expect(checked > 300)
        // An emoji's variation selector is shown too.
        #expect(PermissionText.escape("❤\u{FE0F}", multiline: true) == "❤⟨U+FE0F⟩")
    }

    // MARK: Combining marks

    /// Swift compares strings by canonical equivalence, so a composed and a decomposed text are equal; the scalars tell them apart.
    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    @Test func aKoreanPathMacOSStoredDecomposedReadsAsNormalHangul() throws {
        let decomposed = "/Users/me/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}/\u{110B}\u{1175}\u{1105}\u{1161}\u{11A8}\u{1109}\u{1165}.txt"
        let composed = "/Users/me/한글/이락서.txt"
        #expect(scalars(decomposed) != scalars(composed))
        #expect(scalars(PermissionText.escape(decomposed, multiline: false)) == scalars(composed))
        let prompt = try #require(parse("Read", ["file_path": decomposed])).prompt
        #expect(scalars(prompt.detail) == scalars(composed))
    }

    @Test func accentsOnLatinLettersComposeAndStayReadable() throws {
        let decomposed = "re\u{301}sume\u{301}-nai\u{308}ve.pdf"
        #expect(scalars(PermissionText.escape(decomposed, multiline: false)) == scalars("r\u{E9}sum\u{E9}-na\u{EF}ve.pdf"))
        #expect(scalars(try #require(parse("Read", ["file_path": "/a/" + decomposed])).prompt.detail) == scalars("/a/r\u{E9}sum\u{E9}-na\u{EF}ve.pdf"))
        // A letter that has no composed form keeps its marks, up to two.
        #expect(scalars(PermissionText.escape("x\u{301}\u{323}", multiline: false)) == [0x78, 0x323, 0x301])
    }

    @Test func combiningMarksPastTwoOnOneBaseAreWrittenOut() {
        let escape = "⟨U+0301⟩"
        // "s" with the first acute composes to U+015B; the 39 marks left then count from zero: two stay, 37 are written out.
        let ls = PermissionText.escape("ls" + String(repeating: "\u{301}", count: 40), multiline: false)
        #expect(Array(scalars(ls).prefix(4)) == [0x6C, 0x15B, 0x301, 0x301])
        #expect(ls.components(separatedBy: escape).count - 1 == 37)
        #expect(ls.unicodeScalars.filter { $0.value == 0x301 }.count == 2)

        let x = PermissionText.escape("x" + String(repeating: "\u{323}", count: 40), multiline: false)
        #expect(x.components(separatedBy: "⟨U+0323⟩").count - 1 == 38 && x.unicodeScalars.filter { $0.value == 0x323 }.count == 2)
        // Marks after a line break or an escape start a count of their own; a mark before any base counts too.
        #expect(scalars(PermissionText.escape("x\u{323}\u{323}\u{323}\n\u{323}\u{323}\u{323}", multiline: true))
                == scalars("x\u{323}\u{323}⟨U+0323⟩\n\u{323}\u{323}⟨U+0323⟩"))
        #expect(scalars(PermissionText.escape("\u{200B}\u{323}\u{323}\u{323}", multiline: true)) == scalars("⟨U+200B⟩\u{323}\u{323}⟨U+0323⟩"))
        // Two marks on each of two letters are all kept.
        #expect(scalars(PermissionText.escape("x\u{20D2}\u{20D3}y\u{20D2}\u{20D3}", multiline: false)) == [0x78, 0x20D2, 0x20D3, 0x79, 0x20D2, 0x20D3])
    }

    @Test func theLimitCountsScalarsNotCharacters() {
        // A letter with two marks is one character and three scalars.
        func command(marks: Int, plain: Int) -> String { "x" + String(repeating: "\u{323}", count: marks) + String(repeating: "b", count: plain) }
        let exact = command(marks: 2, plain: PermissionPrompt.detailLimit - 3)
        #expect(exact.unicodeScalars.count == PermissionPrompt.detailLimit && exact.count == PermissionPrompt.detailLimit - 2)
        #expect(parse("Bash", ["command": exact]) != nil)
        let over = command(marks: 2, plain: PermissionPrompt.detailLimit - 2)
        #expect(over.unicodeScalars.count == PermissionPrompt.detailLimit + 1 && over.count < PermissionPrompt.detailLimit)
        #expect(parse("Bash", ["command": over]) == nil)
        // The marks past two are written out, eight scalars each, and count as such.
        let escaped = command(marks: 4, plain: PermissionPrompt.detailLimit - 5)
        #expect(escaped.unicodeScalars.count == PermissionPrompt.detailLimit && parse("Bash", ["command": escaped]) == nil)
    }

    @Test func everyEscapeInACommandReachesTheDetail() throws {
        let prompt = try #require(parse("Bash", ["command": "git status\u{202E}\u{2066}; rm -rf /\u{FEFF}"])).prompt
        #expect(prompt.detail == "git status⟨U+202E⟩⟨U+2066⟩; rm -rf /⟨U+FEFF⟩")
        let path = try #require(parse("Edit", ["file_path": "/a/\u{200B}.ssh/config"])).prompt
        #expect(path.detail == "/a/⟨U+200B⟩.ssh/config")
        let folder = try #require(parse("Bash", ["command": "ls"], cwd: "/x/pro\u{202E}j")).prompt.folder
        #expect(folder == "pro⟨U+202E⟩j")
    }

    // MARK: Long commands

    @Test func aLongCommandIsKeptWholeWithItsEnd() throws {
        let command = (1...400).map { "step \($0) of the build" }.joined(separator: "\n") + "\nrm -rf ~/the-end"
        #expect(command.count < PermissionPrompt.detailLimit)
        let prompt = try #require(parse("Bash", ["command": command])).prompt
        #expect(prompt.detail == command)
        #expect(prompt.detail.hasSuffix("the-end"))
    }

    @Test func whatIsTooLongToShowInFullIsLeftToTheTerminalNotCut() {
        #expect(parse("Bash", ["command": String(repeating: "a", count: PermissionPrompt.detailLimit)]) != nil)
        #expect(parse("Bash", ["command": String(repeating: "a", count: PermissionPrompt.detailLimit + 1)]) == nil)
        // The escapes count: each of these takes eight characters on the card.
        #expect(parse("Bash", ["command": String(repeating: "\u{200B}", count: PermissionPrompt.detailLimit / 8 + 1)]) == nil)
        #expect(parse("Write", ["file_path": String(repeating: "/a", count: PermissionPrompt.detailLimit)]) == nil)
    }

    // MARK: What "Always allow" would add

    @Test func aModeChangeIsNeverTheRuleOffered() throws {
        let deny: [String: Any] = ["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]
        let empty: [String: Any] = ["type": "addRules", "behavior": "allow", "rules": []]
        let only = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, deny, empty]))
        #expect(only.prompt.grant == nil && only.suggestion == nil)

        let both = try #require(parse("Bash", ["command": "ls"], suggestions: [PermissionTestServer.setMode, PermissionTestServer.addRules]))
        #expect(both.prompt.grant?.rules == ["Bash(npm run *)"])
        #expect(both.suggestion?["type"] as? String == "addRules")
    }

    @Test func everyRuleOfTheSuggestionIsShownAsClaudeCodeWritesItAndTheSuggestionIsEchoedAsItIs() throws {
        let rules: [[String: Any]] = [["toolName": "WebFetch"], ["toolName": "Read", "ruleContent": "/a/**"],
                                      ["toolName": "Bash", "ruleContent": "git status:*"]]
        let suggestion = addRules(rules, destination: "projectSettings")
        let parsed = try #require(parse("WebFetch", ["url": "https://x.y"], suggestions: [suggestion]))
        #expect(parsed.prompt.grant == PermissionPrompt.Grant(rules: ["WebFetch", "Read(/a/**)", "Bash(git status:*)"], place: .projectSettings))
        #expect(NSDictionary(dictionary: try #require(parsed.suggestion)).isEqual(to: suggestion))
    }

    @Test func theButtonSaysWhereTheRuleIsSaved() throws {
        let places: [(String, PermissionPrompt.Grant.Place, String)] = [
            ("localSettings", .localSettings, "in this project, just for you"),
            ("projectSettings", .projectSettings, "in this project"),
            ("userSettings", .userSettings, "everywhere"),
            ("session", .session, "for this session"),
        ]
        for (destination, place, phrase) in places {
            let rule = addRules([["toolName": "Bash", "ruleContent": "ls:*"]], destination: destination)
            let parsed = try #require(parse("Bash", ["command": "ls"], suggestions: [rule]))
            let grant = try #require(parsed.prompt.grant, "\(destination)")
            #expect(grant.place == place && grant.place.phrase == phrase, "\(destination)")
        }
    }

    @Test func aRuleThatCouldNotBeShownAsItIsIsNotOffered() throws {
        let fine: [String: Any] = ["toolName": "Bash", "ruleContent": "ls:*"]
        let cases: [(String, [String: Any])] = [
            ("four rules", addRules(Array(repeating: fine, count: 4))),
            ("a newline in a rule", addRules([["toolName": "Bash", "ruleContent": "ls\nrm -rf /"]])),
            ("a direction override", addRules([["toolName": "Bash", "ruleContent": "ls\u{202E}"]])),
            ("a tab", addRules([["toolName": "Bash", "ruleContent": "a\tb"]])),
            ("four words of 29 that wrap to four rows though 125 characters is three rows of a character count",
             addRules([["toolName": "Bash", "ruleContent": Array(repeating: String(repeating: "x", count: 29), count: 4).joined(separator: " ")]])),
            ("a rule too long for three rows", addRules([["toolName": "Bash", "ruleContent": String(repeating: "x", count: 200)]])),
            ("a rule that is not an object", addRules([fine, ["noName": 1]])),
            ("a rule that is a string", ["type": "addRules", "behavior": "allow", "destination": "session", "rules": ["Bash"]]),
            ("a rule without a tool", addRules([["ruleContent": "ls"]])),
            ("a tool name that is empty", addRules([["toolName": ""]])),
            ("a rule with a key nobody knows", addRules([["toolName": "Bash", "ruleContent": "ls", "extra": "x"]])),
            ("a rule content that is not text", addRules([["toolName": "Bash", "ruleContent": 5]])),
            ("a rule content that is empty", addRules([["toolName": "Bash", "ruleContent": ""]])),
            ("a suggestion with a key nobody knows", {
                var suggestion = addRules([fine]); suggestion["directories"] = ["/"]; return suggestion }()),
            ("no place", addRules([fine], destination: nil)),
            ("a place that is not known", addRules([fine], destination: "everyone")),
        ]
        for (name, suggestion) in cases {
            let parsed = try #require(parse("Bash", ["command": "ls"], suggestions: [suggestion]), Comment(rawValue: name))
            #expect(parsed.prompt.grant == nil, Comment(rawValue: name))
            #expect(parsed.suggestion == nil, Comment(rawValue: name))
        }
    }

    @Test func threeRulesAreTheMostOffered() throws {
        let rules = (1...3).map { ["toolName": "Bash", "ruleContent": "cmd\($0):*"] as [String: Any] }
        #expect(try #require(parse("Bash", ["command": "ls"], suggestions: [addRules(rules)])).prompt.grant?.rules.count == 3)
    }
}

@MainActor
struct PermissionBoardTests {
    private func prompt(_ detail: String, grant: PermissionPrompt.Grant? = nil) -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, folder: "proj", grant: grant)
    }

    /// Time that moves only when a test says so.
    final class Clock {
        var now: TimeInterval = 1_000
    }

    @Test func promptsQueueOldestFirstAndEachIsAnsweredOnce() {
        let board = PermissionBoard()
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let first = prompt("one"), second = prompt("two")
        board.add(first)
        board.add(second)
        #expect(board.current == first && board.prompts.count == 2)
        board.answer(first, .allow)
        board.answer(first, .deny)
        #expect(board.current == second)
        #expect(answers.count == 1 && answers[0].0 == first.id && answers[0].1 == .allow)
    }

    @Test func aHookThatIsGoneTakesItsPromptAwayWithoutAnAnswer() {
        let board = PermissionBoard()
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let first = prompt("one"), second = prompt("two")
        board.add(first)
        board.add(second)
        board.remove(first.id)
        #expect(board.prompts == [second])
        board.answer(first, .allow)
        #expect(answers == 0)
        board.clear()
        #expect(board.current == nil)
    }

    @Test func theClosedNotchGrowsForAPromptWhateverElseItShows() {
        let notch = CGSize(width: 200, height: 32), brow = CGSize(width: 44, height: 18)
        let live = HUDEvent.notice(symbol: "bolt", title: "Hi", detail: nil)
        for (base, hasNotch) in [(notch, true), (brow, false)] {
            let plain = NotchViewModel.collapsedSize(base: base, hasNotch: hasNotch, screenWidth: 1440, event: nil, showsLiveActivity: false,
                                                     earWidth: 38, idleGrowth: nil, showsSneakPeek: false, inlinePeekWidth: 240)
            let asked = NotchViewModel.collapsedSize(base: base, hasNotch: hasNotch, screenWidth: 1440, event: live, showsLiveActivity: true,
                                                     earWidth: 38, idleGrowth: 140, showsSneakPeek: true, inlinePeekWidth: 240,
                                                     approvalHeight: 90)
            #expect(asked.height == plain.height + 90)
            #expect(asked.width >= NotchViewModel.approvalWidth)
        }
    }

    // MARK: Accidental clicks

    private func board(_ clock: Clock) -> PermissionBoard {
        PermissionBoard(gate: PermissionClickGate(clock: { clock.now }))
    }

    @Test func aClickJustAfterACardAppearsDoesNotAnswerIt() {
        let clock = Clock(), board = board(clock)
        var answers: [PermissionAnswer] = []
        board.onAnswer = { answers.append($1) }
        let first = prompt("one")
        board.add(first)
        #expect(!board.gate.isReady)
        board.gate.pressBegan()
        board.answerByClick(first, .allow)
        clock.now += PermissionClickGate.delay - 0.01
        board.gate.pressBegan()
        board.answerByClick(first, .allow)
        #expect(answers.isEmpty && board.current == first)

        clock.now += 0.02
        board.gate.pressBegan()
        clock.now += 0.1
        board.answerByClick(first, .allow)
        #expect(answers == [.allow] && board.current == nil)
    }

    @Test func aClickThatBeganBeforeTheDelayEndedDoesNotCountWhenItEndsAfter() {
        let clock = Clock(), board = board(clock)
        var answers = 0
        board.onAnswer = { _, _ in answers += 1 }
        let first = prompt("one")
        board.add(first)
        clock.now += 0.3
        board.gate.pressBegan()
        clock.now += 2
        board.gate.refresh()
        #expect(board.gate.isReady)
        board.answerByClick(first, .deny)
        #expect(answers == 0 && board.current == first)
    }

    @Test func theNextCardInTheQueueGetsTheDelayAgain() {
        let clock = Clock(), board = board(clock)
        var answers: [(UUID, PermissionAnswer)] = []
        board.onAnswer = { answers.append(($0, $1)) }
        let first = prompt("one"), second = prompt("two"), third = prompt("three")
        board.add(first)
        board.add(second)
        board.add(third)
        clock.now += 1
        board.gate.refresh()
        #expect(board.gate.isReady)
        board.answerByClick(first, .allow)
        // The first was answered; the second is in front now, and a click aimed at the first lands on it.
        #expect(answers.count == 1 && board.current == second && !board.gate.isReady)
        board.answerByClick(second, .allow)
        #expect(answers.count == 1 && board.current == second)

        clock.now += 1
        board.gate.refresh()
        board.gate.pressBegan()
        // The hook of the front card is gone, so the third takes its place under the same mouse button.
        board.remove(second.id)
        #expect(board.current == third && !board.gate.isReady)
        clock.now += 0.1
        board.answerByClick(third, .allow)
        clock.now += 1
        board.answerByClick(third, .allow)
        #expect(answers.count == 1 && board.current == third, "a press that began on the card before is not a click on this one")

        board.gate.pressBegan()
        board.answerByClick(third, .allow)
        #expect(answers.count == 2 && board.current == nil)
    }

    @Test func aCardThatAppearsAgainGetsTheDelayAgain() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        clock.now += 1
        #expect(gate.accepts() && gate.isReady)
        gate.arm()
        #expect(!gate.isReady && !gate.accepts())
    }

    @Test func theDelayIsAboutSevenTenthsOfASecond() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        #expect(PermissionClickGate.delay == 0.7)
        #expect(!gate.accepts(), "never armed")
        gate.arm()
        clock.now += 0.699
        gate.refresh()
        #expect(!gate.isReady && !gate.accepts())
        clock.now += 0.002
        gate.refresh()
        #expect(gate.isReady && gate.accepts())
    }

    @Test func aPressBeforeTheCardChangedNeverCountsOnTheNewOne() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        clock.now += 1
        gate.pressBegan()
        clock.now += 0.1
        gate.arm()
        clock.now += 5
        #expect(!gate.accepts())
        gate.pressBegan()
        #expect(gate.accepts())
    }

    @Test func aReleaseWithoutAPressIsAnActivationByAccessibilityAndCountsOnceTheDelayIsOver() {
        let clock = Clock(), gate = PermissionClickGate(clock: { clock.now })
        gate.arm()
        #expect(!gate.accepts())
        clock.now += 1
        #expect(gate.accepts())
    }

    @Test func theButtonsAreLiveOnceTheRealDelayHasPassed() async {
        let gate = PermissionClickGate()
        gate.arm()
        #expect(!gate.isReady)
        await eventually { gate.isReady }
        #expect(gate.isReady)
    }

    // MARK: Room

    @Test func aLongCommandShowsAFewRowsAndSaysThereIsMore() {
        func shown(_ detail: String, grant: PermissionPrompt.Grant? = nil) -> (rows: Int, hidden: Int) {
            let prompt = prompt(detail, grant: grant)
            let visible = PermissionLayout.visibleDetail(prompt, .card)
            return (PermissionLayout.rows(visible), PermissionLayout.hiddenRows(content: prompt.measure(.card).scroll, visible: visible))
        }
        #expect(shown("ls").rows == 1 && shown("ls").hidden == 0)
        #expect(shown("a\nb\nc").rows == 3 && shown("a\nb\nc").hidden == 0)
        let six = (1...6).map(String.init).joined(separator: "\n")
        #expect(shown(six).rows == 6 && shown(six).hidden == 0)
        let seven = (1...7).map(String.init).joined(separator: "\n")
        #expect(shown(seven).rows == 6 && shown(seven).hidden == 1)
        // One line that wraps counts for the rows it takes.
        let wide = String(repeating: "x", count: 50 * 7)
        #expect(shown(wide).rows == 6 && shown(wide).hidden > 0)
        let rule = PermissionPrompt.Grant(rules: ["Bash(a:*)", "Bash(b:*)", "Bash(c:*)"], place: .session)
        #expect(shown(six, grant: rule).rows == 3 && shown(six, grant: rule).hidden == 3)
    }

    @Test func noPromptTakesMoreRoomThanTheNotchHas() {
        let rules = [1, 2, 3].map { "Bash(\(String(repeating: "r", count: 40 * $0)):*)" }
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(ls:*)"], place: .session),
                                                 .init(rules: Array(rules.prefix(1)), place: .userSettings),
                                                 .init(rules: ["a", "b", "c"], place: .projectSettings)]
        let details = ["", "ls", String(repeating: "line\n", count: 3) + "x", String(repeating: "line\n", count: 100),
                       String(repeating: "w", count: 20_000)]
        for grant in grants {
            for detail in details {
                let prompt = PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail,
                                              flags: [.init(text: "Sandbox off", warns: true), .init(text: "Runs in the background", warns: false)],
                                              secondary: "description\ntimeout: 5", folder: "proj", grant: grant)
                // The closed card under the top row of a tall notch, and the open panel under the header, in the window's 280 points.
                #expect(PermissionCard.bodyHeight(for: prompt, hasNotch: true) + 40 <= 280, "\(grant?.rules.count ?? 0) rules, \(detail.count) characters")
                #expect(PermissionPanel.height(for: prompt) <= AppSettings.expandedHeightRange.upperBound - 56,
                        "\(grant?.rules.count ?? 0) rules, \(detail.count) characters")
            }
        }
    }

    @Test func theCardIsTallerForARuleAndForAnOpenTitleLine() {
        func height(grant: PermissionPrompt.Grant?, hasNotch: Bool) -> CGFloat {
            PermissionCard.bodyHeight(for: prompt("d", grant: grant), hasNotch: hasNotch)
        }
        let rule = PermissionPrompt.Grant(rules: ["Bash(ls)"], place: .session)
        #expect(height(grant: rule, hasNotch: true) > height(grant: nil, hasNotch: true))
        #expect(height(grant: nil, hasNotch: true) > height(grant: nil, hasNotch: false))
    }
}
