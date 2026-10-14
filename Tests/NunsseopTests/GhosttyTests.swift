import AppKit
import Testing
@testable import Nunsseop

// Sending to a session in Ghostty. Ghostty is found by its tabs' folders and titles through AppleScript; nothing here talks to a real
// Ghostty: the runner is a stand-in, and the one script that is run for real is run against made-up tabs, with no app named.

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func tab(_ id: String, _ cwd: String, _ name: String = "✳ Claude Code") -> GhosttyTerminal { GhosttyTerminal(id: id, cwd: cwd, name: name) }

struct GhosttyFolderTests {
    @Test func aFolderIsComparedWithoutDotsSlashesOrThePrivatePrefixOfMacOSLinks() {
        #expect(Ghostty.normalized("/Users/me/proj") == "/Users/me/proj")
        #expect(Ghostty.normalized("/Users/me/proj/") == "/Users/me/proj")
        #expect(Ghostty.normalized("//Users//me/./proj/x/..") == "/Users/me/proj")
        #expect(Ghostty.normalized("/private/var/folders/ab/T/x") == "/var/folders/ab/T/x")
        #expect(Ghostty.normalized("/private/tmp") == "/tmp")
        #expect(Ghostty.normalized("/private/etc/hosts") == "/etc/hosts")
        // Only those three are links; another folder named private is a folder.
        #expect(Ghostty.normalized("/private/Users/me") == "/private/Users/me")
        #expect(Ghostty.normalized("/privatevar") == "/privatevar")
        #expect(Ghostty.normalized("/") == "/" && Ghostty.normalized("/..") == "/")
        for bad in ["", "proj", "~/proj", "/a\nb", "/a\u{1b}b"] { #expect(Ghostty.normalized(bad) == nil, Comment(rawValue: bad)) }
    }

    @Test func theSendScriptAcceptsTheSpellingsOfAFolderItCannotNormalize() {
        #expect(Ghostty.spellings(of: "/Users/me/proj") == ["/Users/me/proj", "/Users/me/proj/"])
        #expect(Ghostty.spellings(of: "/var/folders/x") == ["/var/folders/x", "/var/folders/x/", "/private/var/folders/x", "/private/var/folders/x/"])
        #expect(Ghostty.spellings(of: "/tmp") == ["/tmp", "/tmp/", "/private/tmp", "/private/tmp/"])
        #expect(Ghostty.spellings(of: "/") == ["/"])
        // The same folder spelled any of those ways normalizes to it.
        for spelling in Ghostty.spellings(of: "/var/folders/x") { #expect(Ghostty.normalized(spelling) == "/var/folders/x") }
    }

    @Test func theListingIsReadBackIntoTerminalsWhateverTheirTitlesHold() {
        let title = "a\tb\nc | ✳ \"q\" 日本語"
        let text = "T1\u{1F}/Users/me/a\u{1F}\(title)\u{1E}T2\u{1F}\u{1F}\u{1E}T3\u{1F}/tmp\u{1F}x\u{1E}"
        #expect(Ghostty.parse(text) == [tab("T1", "/Users/me/a", title), tab("T2", "", ""), tab("T3", "/tmp", "x")])
        #expect(Ghostty.parse("") == [])
        // A record that isn't three fields, or has no id, is no terminal.
        #expect(Ghostty.parse("T1\u{1F}/a\u{1E}\u{1F}/b\u{1F}c\u{1E}junk\u{1E}") == [])
    }
}

struct GhosttyResolutionTests {
    @Test func theOnlyTerminalInTheFolderIsTheSessionsWhateverItsNameWhenItsTitleIsClaudes() {
        let tabs = [tab("A", "/Users/me/proj", "✳ Claude Code"), tab("B", "/Users/me/other")]
        #expect(Ghostty.resolve(cwd: "/Users/me/proj", name: nil, in: tabs) == .terminal(id: "A", usesName: false))
        #expect(Ghostty.resolve(cwd: "/Users/me/proj", name: "a name no title holds", in: tabs) == .terminal(id: "A", usesName: false))
        #expect(Ghostty.resolve(cwd: "/Users/me/proj", name: nil, in: []) == .absent)
        #expect(Ghostty.resolve(cwd: "/Users/me/nothing", name: nil, in: tabs) == .absent)
        #expect(Ghostty.resolve(cwd: "relative", name: nil, in: tabs) == .absent)
        #expect(Ghostty.resolve(cwd: "", name: nil, in: tabs) == .absent)
    }

    @Test func theFolderIsComparedAfterNormalizingBothSides() {
        let tabs = [tab("A", "/private/var/folders/x/T/proj/"), tab("B", "/Users/me//proj/.")]
        #expect(Ghostty.resolve(cwd: "/var/folders/x/T/proj", name: nil, in: tabs) == .terminal(id: "A", usesName: false))
        #expect(Ghostty.resolve(cwd: "/private/var/folders/x/T/proj", name: nil, in: tabs) == .terminal(id: "A", usesName: false))
        #expect(Ghostty.resolve(cwd: "/Users/me/proj/", name: nil, in: tabs) == .terminal(id: "B", usesName: false))
        // A terminal that doesn't say its folder is in none.
        #expect(Ghostty.resolve(cwd: "/", name: nil, in: [tab("A", "")]) == .absent)
    }

    @Test func severalTerminalsInTheFolderAreToldApartByTheSessionsNameInTheTitle() {
        let tabs = [tab("A", "/p", "✳ fix the login bug"), tab("B", "/p", "◑ write the docs"), tab("C", "/q", "fix the login bug")]
        #expect(Ghostty.resolve(cwd: "/p", name: "fix the login", in: tabs) == .terminal(id: "A", usesName: true))
        #expect(Ghostty.resolve(cwd: "/p", name: "write the docs", in: tabs) == .terminal(id: "B", usesName: true))
        // Case counts: the title carries the name as it is.
        #expect(Ghostty.resolve(cwd: "/p", name: "FIX THE LOGIN", in: tabs) == .ambiguous)
    }

    @Test func severalTerminalsWithoutAUsableNameAreAmbiguous() {
        let tabs = [tab("A", "/p", "✳ fix the login bug"), tab("B", "/p", "◑ fix the login docs")]
        // No name, or one under four characters (which is in too many titles), or one in no title, or in more than one.
        for name in [nil, "", "fix", "abc"] { #expect(Ghostty.resolve(cwd: "/p", name: name, in: tabs) == .ambiguous, Comment(rawValue: name ?? "nil")) }
        #expect(Ghostty.resolve(cwd: "/p", name: "something else", in: tabs) == .ambiguous)
        #expect(Ghostty.resolve(cwd: "/p", name: "fix the login", in: tabs) == .ambiguous)
        // Exactly four characters is enough.
        #expect(Ghostty.resolve(cwd: "/p", name: "docs", in: tabs) == .terminal(id: "B", usesName: true))
    }

    @Test func aTabWhoseTitleIsNotClaudesIsNeverTheSessionsNotEvenByName() {
        // The session's own tab still has its default title; the plain shell's title is its folder, which holds the session's name.
        let path = [tab("T1", "/Users/me/Nunsseop-terms", "✳ Claude Code"), tab("T2", "/Users/me/Nunsseop-terms", "~/Nunsseop-terms")]
        #expect(Ghostty.resolve(cwd: "/Users/me/Nunsseop-terms", name: "Nunsseop-terms", in: path) == .ambiguous)
        // A command that holds a short, ordinary name.
        let command = [tab("T1", "/p", "✳ Claude Code"), tab("T2", "/p", "npm test")]
        #expect(Ghostty.resolve(cwd: "/p", name: "test", in: command) == .ambiguous)
        // Two plain shells, the name in one's title.
        #expect(Ghostty.resolve(cwd: "/p", name: "test", in: [tab("T1", "/p", "zsh"), tab("T2", "/p", "npm test")]) == .ambiguous)
        // Its own title with the name behind a mark still is found, beside the plain one.
        #expect(Ghostty.resolve(cwd: "/p", name: "test", in: [tab("T1", "/p", "✳ test the login"), tab("T2", "/p", "npm test")])
                == .terminal(id: "T1", usesName: true))
    }

    @Test func aTitleIsClaudesWhenItHoldsOneMarkASpaceAndText() {
        for title in ["✳ Claude Code", "◑ fix the login", "⠂ x", "✻ ab", "\u{2190} x", "\u{2BFF} x", "✳ a b ✳", "✳  "] {
            #expect(Ghostty.claudeTitle(title) != nil, Comment(rawValue: title))
        }
        for title in ["", "zsh", "~/proj", "npm test", "* x", "✳", "✳ ", "✳x", " ✳ x", "가 x", "1 x", "🎉 x", "✳\u{FE0F} x", "✳✳ x", "\u{218F} x", "\u{2C00} x"] {
            #expect(Ghostty.claudeTitle(title) == nil, Comment(rawValue: title))
        }
        #expect(Ghostty.claudeTitle("✳ fix the login") == "fix the login")
    }

    @Test func theOnlyTerminalInTheFolderMustLookLikeAnAgentsTab() {
        // The session's own tab reports no folder (or a stale one), and a plain shell is the only one in the session's folder.
        let tabs = [tab("S", "", "✳ Claude Code"), tab("P", "/Users/me/proj", "zsh")]
        #expect(Ghostty.resolve(cwd: "/Users/me/proj", name: nil, in: tabs) == .absent)
        #expect(Ghostty.resolve(cwd: "/Users/me/proj", name: "fix the login", in: tabs) == .absent)
        for title in ["npm run dev", "~/proj", "", "vim"] {
            #expect(Ghostty.resolve(cwd: "/p", name: nil, in: [tab("A", "/p", title)]) == .absent, Comment(rawValue: title))
        }
        // The same tab with a Claude title is the session's.
        #expect(Ghostty.resolve(cwd: "/p", name: nil, in: [tab("A", "/p", "◑ npm run dev")]) == .terminal(id: "A", usesName: false))
    }

    @Test func aLoneFolderMatchIsNotTakenWhenAnotherTabsTitleHoldsTheSessionsName() {
        // The transcript's folder (/proj/web) is not the session tab's (/proj); a Claude tab of another session sits in it.
        let tabs = [tab("T1", "/proj", "✳ Fix login"), tab("T2", "/proj/web", "◑ Review notes")]
        #expect(Ghostty.resolve(cwd: "/proj/web", name: "Fix login", in: tabs) == .ambiguous)
        // Without a name to look for (none, or under four characters), there is nothing to contradict the folder.
        #expect(Ghostty.resolve(cwd: "/proj/web", name: nil, in: tabs) == .terminal(id: "T2", usesName: false))
        #expect(Ghostty.resolve(cwd: "/proj/web", name: "Fix", in: tabs) == .terminal(id: "T2", usesName: false))
        // A name that is in no other title, or in the tab's own, changes nothing.
        #expect(Ghostty.resolve(cwd: "/proj/web", name: "Review notes", in: tabs) == .terminal(id: "T2", usesName: false))
        #expect(Ghostty.resolve(cwd: "/proj/web", name: "Something else", in: tabs) == .terminal(id: "T2", usesName: false))
        // The name in a tab that isn't Claude's is no contradiction.
        #expect(Ghostty.resolve(cwd: "/proj/web", name: "Fix login", in: [tab("T1", "/proj", "vim Fix login"), tab("T2", "/proj/web")])
                == .terminal(id: "T2", usesName: false))
        // Two sessions of one name in two folders: each tab holds it, and each is found by its folder.
        let twins = [tab("A", "/p", "✳ Fix login"), tab("B", "/q", "◑ Fix login")]
        #expect(Ghostty.resolve(cwd: "/p", name: "Fix login", in: twins) == .terminal(id: "A", usesName: false))
    }

    private func session(_ key: String, _ cwd: String, _ name: String?) -> GhosttySession { GhosttySession(key: key, cwd: cwd, name: name) }

    @Test func sessionsOfDifferentFoldersAreResolvedEachOnItsOwn() {
        let tabs = [tab("A", "/p"), tab("B", "/q")]
        let tabsByKey = Ghostty.resolve([session("1", "/p", nil), session("2", "/q", "name"), session("3", "/gone", nil)], in: tabs)
        #expect(tabsByKey == ["1": .terminal(id: "A", usesName: false), "2": .terminal(id: "B", usesName: false), "3": .absent])
    }

    @Test func twoSessionsInOneFolderMustEachBeToldApartByNameElseBothAreAmbiguous() {
        let tabs = [tab("A", "/p", "✳ fix the login bug"), tab("B", "/p", "◑ write the docs")]
        let apart = Ghostty.resolve([session("1", "/p", "fix the login"), session("2", "/p", "write the docs")], in: tabs)
        #expect(apart == ["1": .terminal(id: "A", usesName: true), "2": .terminal(id: "B", usesName: true)])
        // One with no name: it can't be told, and so neither can the other, which might be taken for it.
        let oneNameless = Ghostty.resolve([session("1", "/p", "fix the login"), session("2", "/p", nil)], in: tabs)
        #expect(oneNameless == ["1": .ambiguous, "2": .ambiguous])
        // The same name for both.
        let same = Ghostty.resolve([session("1", "/p", "fix the login"), session("2", "/p", "fix the login")], in: tabs)
        #expect(same == ["1": .ambiguous, "2": .ambiguous])
        // Two sessions, one terminal: both resolve to it, and it can't be both's.
        let one = Ghostty.resolve([session("1", "/p", "fix the login"), session("2", "/p", "write the docs")], in: [tab("A", "/p")])
        #expect(one == ["1": .ambiguous, "2": .ambiguous])
        // A third session elsewhere is unaffected.
        let third = Ghostty.resolve([session("1", "/p", nil), session("2", "/p", nil), session("3", "/q", nil)], in: tabs + [tab("C", "/q")])
        #expect(third == ["1": .ambiguous, "2": .ambiguous, "3": .terminal(id: "C", usesName: false)])
    }

    @Test func twoSessionsInOneFolderEquallySpelledAreOneFolder() {
        let tabs = [tab("A", "/private/tmp/p", "one"), tab("B", "/tmp/p", "two")]
        let tabsByKey = Ghostty.resolve([session("1", "/tmp/p/", nil), session("2", "/private/tmp/p", nil)], in: tabs)
        #expect(tabsByKey == ["1": .ambiguous, "2": .ambiguous])
    }

    @Test func sessionsWithNoTerminalInTheirSharedFolderAreAbsentNotAmbiguous() {
        let tabsByKey = Ghostty.resolve([session("1", "/p", nil), session("2", "/p", nil)], in: [tab("A", "/q")])
        #expect(tabsByKey == ["1": .absent, "2": .absent])
    }
}

/// Answers the calls made to Ghostty from a list that a test can change, and records them.
private final class FakeGhostty: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AppleScriptCall] = []
    private var reply: ScriptResult
    init(_ reply: ScriptResult = .value("")) { self.reply = reply }

    var answer: ScriptResult {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }
    var calls: [AppleScriptCall] { lock.withLock { all } }
    var listings: Int { calls.filter { $0.handler == "list_terminals" }.count }

    func tabs(_ terminals: [GhosttyTerminal]) {
        answer = .value(terminals.map { "\($0.id)\u{1F}\($0.cwd)\u{1F}\($0.name)\u{1E}" }.joined())
    }

    var runner: AppleScriptRunner {
        AppleScriptRunner { [self] call in lock.withLock { all.append(call); return reply } }
    }
}

struct GhosttyScriptTests {
    private let hostile = "it's \"q\" \\ back\\slash \\n $(touch pwn) `id` \u{1b}[31m 日本語 🎉 \" & (do shell script \"id\") & \""

    @Test func listingAsksGhosttyThatIsRunningAndNeverStartsIt() {
        let fake = FakeGhostty()
        fake.tabs([tab("A", "/p", "✳ t")])
        #expect(Ghostty.list(scripts: fake.runner) == .terminals([tab("A", "/p", "✳ t")]))
        let call = fake.calls[0]
        #expect(call.bundleID == "com.mitchellh.ghostty" && call.handler == "list_terminals" && call.arguments.isEmpty && !call.launches)
        #expect(call.source.contains("application id \"com.mitchellh.ghostty\"") && call.source.contains("working directory of t"))
        fake.answer = .notAllowed
        #expect(Ghostty.list(scripts: fake.runner) == .notAllowed)
        fake.answer = .failed
        #expect(Ghostty.list(scripts: fake.runner) == .unavailable)
        fake.answer = .value("")
        #expect(Ghostty.list(scripts: fake.runner) == .terminals([]))
    }

    @Test func everyCallToGhosttyGivesUpAfterAFewSecondsInsteadOfHoldingTheScriptQueue() {
        let list = TerminalScripts.ghosttyList().source
        let send = TerminalScripts.ghosttySend(terminal: "A", folders: ["/p"], name: "", needsName: false, text: "x", submit: true).source
        #expect(list.contains("with timeout of 3 seconds") && list.contains("end timeout"))
        #expect(send.contains("with timeout of 5 seconds") && send.contains("end timeout"))
        // The timeout wraps the tell, so what waits on Ghostty is inside it.
        for source in [list, send] {
            let lines = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let begin = lines.firstIndex { $0.hasPrefix("with timeout") }, tell = lines.firstIndex { $0.hasPrefix("tell application") }
            let end = lines.firstIndex { $0 == "end timeout" }
            #expect(begin != nil && tell != nil && end != nil && begin! < tell! && tell! < end!)
        }
    }

    @Test func aMessageIsOneHandlerCallWithEverythingAsAnArgumentNotInTheSource() throws {
        let clis = TerminalCLIs()
        let pick = GhosttyPick(terminal: "T-1", usesName: true)
        for submit in [true, false] {
            let steps = try #require(AgentSend.steps(.ghostty(cwd: "/Users/me/proj/", name: "fix the login"), text: hostile, submit: submit, clis: clis, ghostty: pick))
            guard case .script(let call)? = steps.first, steps.count == 1 else { Issue.record("not one script step"); return }
            #expect(call.bundleID == "com.mitchellh.ghostty" && call.handler == "send_text" && call.expecting == "ok" && !call.launches)
            #expect(call.arguments == ["T-1", "/Users/me/proj\n/Users/me/proj/", "fix the login", "1", hostile, submit ? "1" : "0"])
            #expect(!call.source.contains(hostile) && !call.source.contains("pwn") && !call.source.contains("fix the login") && !call.source.contains("T-1"))
            let header = try #require(call.source.split(separator: "\n").first { $0.hasPrefix("on ") })
            #expect(header.hasPrefix("on send_text(") && header.split(separator: ",").count == call.arguments.count)
            // Pasted by `input text`; Return is its own key, and only for a message.
            #expect(call.source.contains("input text theText to found") && call.source.contains("send key \"enter\" to found"))
            for forbidden in ["do shell script", "run script", "osascript", "System Events", "keystroke", "key code"] {
                #expect(!call.source.contains(forbidden), Comment(rawValue: forbidden))
            }
        }
    }

    @Test func theNameIsAlwaysPassedWhenLongEnoughAndRequiredOnlyWhenItToldTheTabsApart() throws {
        func arguments(_ name: String?, usesName: Bool) throws -> [String] {
            let steps = try #require(AgentSend.steps(.ghostty(cwd: "/p", name: name), text: "x", submit: true, clis: TerminalCLIs(),
                                                     ghostty: GhosttyPick(terminal: "A", usesName: usesName)))
            guard case .script(let call) = steps[0] else { Issue.record("no script"); return [] }
            return [call.arguments[2], call.arguments[3]]
        }
        #expect(try arguments("fix the login", usesName: true) == ["fix the login", "1"])
        // Not needed for the pick, but still looked for in the other tabs (a session's folder may not be its tab's).
        #expect(try arguments("fix the login", usesName: false) == ["fix the login", "0"])
        // A name under four characters is in too many titles: never passed, so a pick can't have used it.
        #expect(try arguments("abc", usesName: false) == ["", "0"])
        #expect(try arguments("abc", usesName: true) == ["", "0"])
        #expect(try arguments(nil, usesName: true) == ["", "0"])
    }

    @Test func aDropIsTypedWithoutReturnAndNothingIsSentWithoutAPickOrAFolder() throws {
        let pick = GhosttyPick(terminal: "A", usesName: false)
        let drop = try #require(AgentSend.steps(.ghostty(cwd: "/p", name: nil), text: "/tmp/a.png ", submit: false, clis: TerminalCLIs(), ghostty: pick))
        guard case .script(let call) = drop[0] else { Issue.record("no script"); return }
        #expect(call.arguments[4] == "/tmp/a.png " && call.arguments[5] == "0")
        #expect(AgentSend.steps(.ghostty(cwd: "/p", name: nil), text: "x", submit: true, clis: TerminalCLIs()) == nil)
        #expect(AgentSend.steps(.ghostty(cwd: "not absolute", name: nil), text: "x", submit: true, clis: TerminalCLIs(), ghostty: pick) == nil)
        #expect(AgentInput.ghostty(cwd: "/p", name: nil).takesFiles)
    }

    @Test func theHandlersAnswerDecidesTheOutcome() throws {
        let steps = try #require(AgentSend.steps(.ghostty(cwd: "/p", name: nil), text: "x", submit: true, clis: TerminalCLIs(),
                                                 ghostty: GhosttyPick(terminal: "A", usesName: false)))
        func outcome(_ result: ScriptResult) -> SendOutcome { AgentSend.run(steps, scripts: FakeGhostty(result).runner) }
        #expect(outcome(.value("ok")) == .sent)
        #expect(outcome(.value("gone")) == .failed)
        #expect(outcome(.value("ambiguous")) == .failed)
        #expect(outcome(.failed) == .failed)
        #expect(outcome(.notAllowed) == .notAllowed("com.mitchellh.ghostty"))
    }

    // MARK: the send handler, run for real against made-up tabs

    /// The send script with Ghostty's terms swapped for those of a list of records and its `tell` taken out, so it can run with no app:
    /// what is run is the real text of the handler, tab by tab.
    private func stubbed(_ call: AppleScriptCall, tabs: [(id: String, cwd: String?, name: String?)]) throws -> AppleScriptCall {
        let swaps = [("\ttell application id \"com.mitchellh.ghostty\"\n", ""), ("\tend tell\n", ""),
                     ("working directory of t", "wd of t"), ("name of t", "nm of t"), ("(id of t)", "(tid of t)"),
                     ("set surfaces to terminals", "set surfaces to my fakeTabs()"),
                     ("input text theText to found", "set my typed to theText"), ("send key \"enter\" to found", "set my pressedReturn to true")]
        var source = call.source
        for (from, to) in swaps {
            #expect(source.contains(from), Comment(rawValue: from))
            source = source.replacingOccurrences(of: from, with: to)
        }
        func text(_ value: String?) -> String { value.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? "missing value" }
        let records = tabs.map { "{tid:\(text($0.id)), wd:\(text($0.cwd)), nm:\(text($0.name))}" }.joined(separator: ", ")
        source = """
            property typed : missing value
            property pressedReturn : false
            on fakeTabs()
            \treturn {\(records)}
            end fakeTabs
            on run_send(theID, theFolders, theName, theNeedsName, theText, withReturn)
            \tset answer to send_text(theID, theFolders, theName, theNeedsName, theText, withReturn)
            \treturn answer & "|" & typed & "|" & pressedReturn
            end run_send

            """ + source
        return AppleScriptCall(bundleID: "com.nunsseop.none", source: source, handler: "run_send", arguments: call.arguments, expecting: "", launches: true)
    }

    /// AppleScript yields to the event loop while it runs, and in a process that never connected to the window server that waits half a
    /// minute at a time: the app has it from the start, a test process only once something draws, so this connects first.
    @MainActor
    private func run(_ id: String, cwd: String = "/Users/me/x", name: String? = nil, usesName: Bool = false, submit: Bool = true,
                     tabs: [(id: String, cwd: String?, name: String?)]) async throws -> String {
        let steps = try #require(AgentSend.steps(.ghostty(cwd: cwd, name: name), text: "say \"hi\" \\ there", submit: submit, clis: TerminalCLIs(),
                                                  ghostty: GhosttyPick(terminal: id, usesName: usesName)))
        guard case .script(let call) = steps[0] else { Issue.record("no script"); return "" }
        _ = NSApplication.shared
        let stub = try stubbed(call, tabs: tabs)
        guard case .value(let answer) = await Task.detached(operation: { AppleScriptRunner.live.run(stub) }).value else { return "script failed" }
        return answer
    }

    private let tabs: [(id: String, cwd: String?, name: String?)] = [
        ("A", "/Users/me/x", "✳ fix the login bug"), ("B", "/Users/me/x", "◑ write the docs"), ("C", "/private/tmp/q", "✳ Claude Code"), ("D", "/Users/me/y/", "◑ Claude Code"),
    ]

    @MainActor
    @Test func theHandlerTypesOnlyIntoTheTabThatStillFitsAndIsTheOnlyOne() async throws {
        // Named: A fits by folder and name and B doesn't.
        #expect(try await run("A", name: "fix the login", usesName: true, tabs: tabs) == "ok|say \"hi\" \\ there|true")
        // No Return for a drop.
        #expect(try await run("A", name: "fix the login", usesName: true, submit: false, tabs: tabs) == "ok|say \"hi\" \\ there|false")
        // A tab alone in its folder, in any spelling the script takes.
        #expect(try await run("C", cwd: "/tmp/q", tabs: tabs).hasPrefix("ok|"))
        #expect(try await run("D", cwd: "/Users/me/y", tabs: tabs).hasPrefix("ok|"))
    }

    @MainActor
    @Test func theHandlerRefusesATabThatMovedWasRenamedOrIsGone() async throws {
        // Moved to another folder; renamed so the name is no longer in its title; closed; another session's tab.
        #expect(try await run("A", name: "fix the login", usesName: true, tabs: [("A", "/Users/me/other", "✳ fix the login bug")]) == "gone|missing value|false")
        #expect(try await run("A", name: "fix the login", usesName: true, tabs: [("A", "/Users/me/x", "✳ something else"), ("B", "/Users/me/x", "x")]) == "gone|missing value|false")
        #expect(try await run("A", tabs: [("B", "/Users/me/x", "x")]) == "gone|missing value|false")
        #expect(try await run("B", name: "fix the login", usesName: true, tabs: tabs) == "gone|missing value|false")
        // A tab that doesn't say its folder or title is no fit.
        #expect(try await run("A", tabs: [("A", nil, nil)]) == "gone|missing value|false")
        // Case counts, in the folder and in the name.
        #expect(try await run("A", cwd: "/users/me/x", tabs: tabs) == "gone|missing value|false")
        #expect(try await run("A", name: "FIX THE LOGIN", usesName: true, tabs: tabs) == "gone|missing value|false")
    }

    @MainActor
    @Test func theHandlerRefusesATabWhoseTitleIsNotClaudesWhateverItsName() async throws {
        let shells: [(id: String, cwd: String?, name: String?)] = [("T1", "/Users/me/Nunsseop-terms", "✳ Claude Code"), ("T2", "/Users/me/Nunsseop-terms", "~/Nunsseop-terms")]
        let folder = "/Users/me/Nunsseop-terms"
        #expect(try await run("T2", cwd: folder, name: "Nunsseop-terms", usesName: true, tabs: shells) == "gone|missing value|false")
        #expect(try await run("T2", cwd: folder, name: "Nunsseop-terms", usesName: false, tabs: [shells[1]]) == "gone|missing value|false")
        #expect(try await run("T2", cwd: folder, tabs: [shells[1]]) == "gone|missing value|false")
        // The name is looked for after the mark only, not in the mark.
        #expect(try await run("A", name: "✳ fix", usesName: true, tabs: [("A", "/Users/me/x", "✳ fix"), ("B", "/Users/me/x", "x")]) == "gone|missing value|false")
    }

    @MainActor
    @Test func theHandlerRefusesALoneTabWhenAnotherTabsClaudeTitleHoldsTheNameAndItsOwnDoesNot() async throws {
        let name = "Fix login"
        let elsewhere: (id: String, cwd: String?, name: String?) = ("T1", "/Users/me/other", "✳ Fix login")
        #expect(try await run("T2", name: name, tabs: [elsewhere, ("T2", "/Users/me/x", "◑ Review notes")]) == "ambiguous|missing value|false")
        // Its own title holds it too, or the other title isn't Claude's, or the name is too short or absent: it is the one.
        #expect(try await run("T2", name: name, tabs: [elsewhere, ("T2", "/Users/me/x", "◑ Fix login again")]).hasPrefix("ok|"))
        #expect(try await run("T2", name: name, tabs: [("T1", "/Users/me/other", "vim Fix login"), ("T2", "/Users/me/x", "◑ Review notes")]).hasPrefix("ok|"))
        #expect(try await run("T2", name: "Fix", tabs: [elsewhere, ("T2", "/Users/me/x", "◑ Review notes")]).hasPrefix("ok|"))
        #expect(try await run("T2", tabs: [elsewhere, ("T2", "/Users/me/x", "◑ Review notes")]).hasPrefix("ok|"))
        // A tab picked by its name is not refused for another's holding it.
        #expect(try await run("T2", name: name, usesName: true, tabs: [elsewhere, ("T2", "/Users/me/x", "◑ Fix login"), ("T3", "/Users/me/x", "zsh")]).hasPrefix("ok|"))
    }

    @MainActor
    @Test func theHandlerRefusesALoneTabOnceAnyOtherTabIsInTheFolderToo() async throws {
        // A plain shell went to the folder after the check: the tab is no longer alone, though the shell isn't a fit by title.
        #expect(try await run("A", tabs: [("A", "/Users/me/x", "✳ one"), ("B", "/Users/me/x", "zsh")]) == "ambiguous|missing value|false")
        // A plain shell elsewhere is nothing.
        #expect(try await run("A", tabs: [("A", "/Users/me/x", "✳ one"), ("B", "/Users/me/z", "zsh")]).hasPrefix("ok|"))
    }

    @MainActor
    @Test func theHandlerAndTheResolutionAgreeOnWhichTitlesAreClaudes() async throws {
        let titles = ["✳ Claude Code", "◑ x", "⠂ x", "✻ ab", "\u{2190} x", "\u{218F} x", "\u{2BFF} x", "\u{2C00} x", "zsh", "~/x", "* x", "✳x", "✳ ", "✳",
                      " ✳ x", "가 x", "1 x", "🎉 x", "✳\u{FE0F} x", "✳✳ x", "✳  y", "✳  ", "ab"]
        for title in titles {
            let accepted = try await run("A", tabs: [("A", "/Users/me/x", title)]).hasPrefix("ok|")
            #expect(accepted == (Ghostty.claudeTitle(title) != nil), Comment(rawValue: title))
        }
    }

    @MainActor
    @Test func theHandlerRefusesWhenAnotherTabNowFitsAsWell() async throws {
        // Verified alone in the folder, then a second tab went there; or the name no longer separates them.
        #expect(try await run("A", tabs: [("A", "/Users/me/x", "✳ one"), ("B", "/Users/me/x", "◑ two")]) == "ambiguous|missing value|false")
        #expect(try await run("A", name: "fix it", usesName: true, tabs: [("A", "/Users/me/x", "✳ fix it a"), ("B", "/Users/me/x", "◑ fix it b")]) == "ambiguous|missing value|false")
        // A tab in another folder is no rival.
        #expect(try await run("A", tabs: [("A", "/Users/me/x", "✳ one"), ("B", "/Users/me/z", "◑ two")]).hasPrefix("ok|"))
    }
}

// MARK: the process tree

struct GhosttyHostTests {
    private let claude = "/Users/me/.local/share/claude/versions/2.1"
    private let ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty"

    private func check(_ records: [Int32: ProcessRecord]) -> AgentTargetCheck {
        AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil })
    }

    /// claude, its shell, `login` (which Ghostty runs the shell through), Ghostty.
    private func tree(between: String? = nil) -> [Int32: ProcessRecord] {
        var records: [Int32: ProcessRecord] = [
            100: .init(parent: 101, executable: claude, hasTTY: true), 101: .init(parent: 102, executable: "/bin/zsh", hasTTY: true),
            102: .init(parent: 103, executable: "/usr/bin/login", hasTTY: true), 103: .init(parent: 1, executable: ghostty, hasTTY: false),
        ]
        if let between { records[102] = .init(parent: 104, executable: "/usr/bin/login", hasTTY: true); records[104] = .init(parent: 103, executable: between, hasTTY: false) }
        return records
    }

    @Test func aSessionUnderGhosttyThroughItsShellAndLoginIsInIt() {
        let input = AgentInput.ghostty(cwd: "/p", name: nil)
        #expect(check(tree()).hosted(input, pid: 100))
        #expect(check(tree()).verified(input, pid: 100, muxySessions: nil))
        // Wherever the app is installed, as long as it is Ghostty's.
        var elsewhere = tree()
        elsewhere[103] = .init(parent: 1, executable: "/Users/me/Applications/Ghostty.app/Contents/MacOS/ghostty", hasTTY: false)
        #expect(check(elsewhere).hosted(input, pid: 100))
    }

    @Test func anotherTerminalOrMultiplexerBetweenMeansTheSessionIsNotInGhosttyItself() {
        let input = AgentInput.ghostty(cwd: "/p", name: nil)
        for path in ["/opt/homebrew/bin/tmux", "/opt/homebrew/bin/zellij", "/usr/bin/screen", "/Users/me/.local/bin/herdr",
                     "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                     "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui", "/Applications/Muxy.app/Contents/MacOS/muxy-server"] {
            #expect(!check(tree(between: path)).hosted(input, pid: 100), Comment(rawValue: path))
        }
        #expect(check(tree(between: "/usr/bin/caffeinate")).hosted(input, pid: 100))
    }

    @Test func aSessionWithoutATerminalOrWithAnotherSessionAboveItIsNotInGhostty() {
        let input = AgentInput.ghostty(cwd: "/p", name: nil)
        var headless = tree()
        headless[100] = .init(parent: 101, executable: claude, hasTTY: false)
        #expect(!check(headless).hosted(input, pid: 100))
        // `claude -p` run by another session keeps its parent's terminal.
        var child = tree()
        child[100] = .init(parent: 99, executable: claude, hasTTY: true)
        child[99] = .init(parent: 101, executable: claude, hasTTY: true)
        #expect(!check(child).hosted(input, pid: 100, others: [99, 100]))
        #expect(check(child).hosted(input, pid: 100, others: [100]))
        #expect(!check([:]).hosted(input, pid: 100) && !check(tree()).hosted(input, pid: nil))
    }

    @Test func onlyGhosttysOwnExecutableIsGhostty() {
        #expect(AgentTargetCheck.isGhostty("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
        #expect(!AgentTargetCheck.isGhostty("/Applications/Ghostty.app/Contents/MacOS/other"))
        #expect(!AgentTargetCheck.isGhostty("/usr/local/bin/ghostty"))
        #expect(!AgentTargetCheck.isGhostty("/Applications/NotGhostty.app/Contents/MacOS/ghostty"))
        #expect(AgentTargetCheck.hostsInput("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
        #expect(AgentRow.inputApps.contains("com.mitchellh.ghostty"))
    }
}

// MARK: the model

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[AgentStep]] = []
    var passes = true
    var plans: [[AgentStep]] { lock.withLock { all } }
    var sender: AgentSender {
        AgentSender { [self] steps in lock.withLock { all.append(steps); return passes ? .sent : .failed } }
    }
}

private struct NoEnvironments {
    var variables: [Int32: [String: String]] = [:]
    var environment: ProcessEnvironment { let variables = variables; return ProcessEnvironment { variables[$0] } }
}

@MainActor
struct GhosttyModelTests {
    private let claude = "/Users/me/.local/share/claude/versions/2.1"
    private let ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty"

    /// 100, 200, 300: sessions in Ghostty (shell and `login` between); 400: in tmux under Ghostty; 500: under another app; 600: in Ghostty,
    /// but its hook named Terminal.
    private var tree: [Int32: ProcessRecord] {
        var records: [Int32: ProcessRecord] = [
            10: .init(parent: 11, executable: "/usr/bin/login", hasTTY: true), 11: .init(parent: 1, executable: ghostty, hasTTY: false),
            402: .init(parent: 1, executable: "/opt/homebrew/bin/tmux", hasTTY: false),
            502: .init(parent: 1, executable: "/Applications/NoSuchTerm.app/Contents/MacOS/nosuch", hasTTY: false),
        ]
        for pid in [Int32(100), 200, 300, 600] {
            records[pid] = .init(parent: pid + 1, executable: claude, hasTTY: true)
            records[pid + 1] = .init(parent: 10, executable: "/bin/zsh", hasTTY: true)
        }
        records[400] = .init(parent: 401, executable: claude, hasTTY: true)
        records[401] = .init(parent: 402, executable: "/bin/zsh", hasTTY: true)
        records[500] = .init(parent: 501, executable: claude, hasTTY: true)
        records[501] = .init(parent: 502, executable: "/bin/zsh", hasTTY: true)
        return records
    }

    private func agent(_ pid: Int32?, app: String? = nil, state: AgentBoard.State = .working) -> AgentBoard.Agent {
        AgentBoard.Agent(state: state, since: start, tool: "claude", app: app, pid: pid)
    }

    private func make(_ agents: [String: AgentBoard.Agent], transcripts: [String: AgentTranscript], fake: FakeGhostty, sent: Sent = Sent(),
                      environments: [Int32: [String: String]] = [:]) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let records = tree
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: sent.sender, clis: { TerminalCLIs() },
                                   targets: AgentTargetCheck(processes: ProcessTable { records[$0] }, muxyList: { _ in nil }),
                                   environments: NoEnvironments(variables: environments).environment, scripts: fake.runner)
        model.noteDuration = eventDeadline
        model.fixedRecent = []
        for (id, transcript) in transcripts { model.fixed["hooks:claude|\(id)"] = transcript }
        return model
    }

    private func settle(_ model: AgentsTabModel) async {
        model.refresh(now: start)
        await eventually { !model.verifying }
    }

    private func row(_ model: AgentsTabModel, _ id: String) throws -> AgentRow {
        try #require(model.rows.first { $0.id == "hooks:claude|\(id)" })
    }

    @Test func aSessionAloneInItsFolderCanBeSentToAndTheTabIsFoundBeforeAnythingIsTyped() async throws {
        let fake = FakeGhostty(), sent = Sent()
        fake.tabs([tab("T1", "/Users/me/proj"), tab("T2", "/Users/me/other")])
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj", name: "fix login")], fake: fake, sent: sent)
        await settle(model)
        let ready = try row(model, "a")
        #expect(ready.input == .ghostty(cwd: "/Users/me/proj", name: "fix login") && ready.acceptsInput && ready.inputBlock == nil)
        #expect(fake.listings == 1 && fake.calls.allSatisfy { !$0.launches })
        #expect(model.send(message: "hello", to: ready))
        await eventually { !sent.plans.isEmpty }
        guard case .script(let call)? = sent.plans.first?.first else { Issue.record("not a script"); return }
        #expect(call.handler == "send_text" && call.arguments == ["T1", "/Users/me/proj\n/Users/me/proj/", "fix login", "0", "hello", "1"])
        #expect(model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: ready))
        await eventually { sent.plans.count == 2 }
        guard case .script(let drop)? = sent.plans.last?.first else { Issue.record("not a script"); return }
        #expect(drop.arguments[0] == "T1" && drop.arguments[4] == "/tmp/a.png " && drop.arguments[5] == "0")
        // Nothing was listed again by sending.
        #expect(fake.listings == 1)
    }

    @Test func severalTabsInTheFolderAreToldApartByTheSessionsNameAndTheSendRechecksIt() async throws {
        let fake = FakeGhostty(), sent = Sent()
        fake.tabs([tab("T1", "/Users/me/proj", "✳ fix login"), tab("T2", "/Users/me/proj", "◑ other work")])
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj", name: "fix login")], fake: fake, sent: sent)
        await settle(model)
        #expect(try row(model, "a").acceptsInput)
        #expect(model.send(message: "hi", to: try row(model, "a")))
        await eventually { !sent.plans.isEmpty }
        guard case .script(let call)? = sent.plans.first?.first else { Issue.record("not a script"); return }
        #expect(call.arguments[0] == "T1" && call.arguments[2] == "fix login")
    }

    @Test func severalTabsAndNoNameSayWhyAndSendNothing() async throws {
        let fake = FakeGhostty(), sent = Sent()
        fake.tabs([tab("T1", "/Users/me/proj", "one"), tab("T2", "/Users/me/proj", "two")])
        let model = make(["a": agent(100), "b": agent(200)], transcripts: [
            "a": AgentTranscript(cwd: "/Users/me/proj"), "b": AgentTranscript(cwd: "/Users/me/proj", name: "abc"),
        ], fake: fake, sent: sent)
        await settle(model)
        for id in ["a", "b"] {
            let blocked = try row(model, id)
            #expect(blocked.inputBlock == .ambiguousTab && !blocked.acceptsInput && blocked.input == nil, Comment(rawValue: id))
            #expect(blocked.blockReason == String(localized: "There are several Ghostty tabs in this folder, so Nunsseop can't tell which one"))
            #expect(!model.send(message: "hi", to: blocked) && !model.send(files: [URL(fileURLWithPath: "/tmp/a.png")], to: blocked))
        }
        #expect(sent.plans.isEmpty)
    }

    @Test func twoSessionsInOneFolderAreBothAmbiguousUnlessTheirNamesTellTheirTabsApart() async throws {
        let fake = FakeGhostty()
        fake.tabs([tab("T1", "/Users/me/proj", "✳ fix login"), tab("T2", "/Users/me/proj", "◑ write docs")])
        let apart = make(["a": agent(100), "b": agent(200)], transcripts: [
            "a": AgentTranscript(cwd: "/Users/me/proj", name: "fix login"), "b": AgentTranscript(cwd: "/Users/me/proj", name: "write docs"),
        ], fake: fake)
        await settle(apart)
        #expect(try row(apart, "a").acceptsInput && row(apart, "b").acceptsInput)
        #expect(fake.listings == 1)
        // The same two sessions, one of them unnamed: neither can be told from the other.
        let together = make(["a": agent(100), "b": agent(200)], transcripts: [
            "a": AgentTranscript(cwd: "/Users/me/proj", name: "fix login"), "b": AgentTranscript(cwd: "/Users/me/proj"),
        ], fake: fake)
        await settle(together)
        #expect(try row(together, "a").inputBlock == .ambiguousTab && row(together, "b").inputBlock == .ambiguousTab)
        // And two sessions with one tab between them (the other is not a Ghostty tab, or was closed).
        fake.tabs([tab("T1", "/Users/me/proj")])
        let shared = make(["a": agent(100), "b": agent(200)], transcripts: [
            "a": AgentTranscript(cwd: "/Users/me/proj", name: "fix login"), "b": AgentTranscript(cwd: "/Users/me/proj", name: "write docs"),
        ], fake: fake)
        await settle(shared)
        #expect(try row(shared, "a").inputBlock == .ambiguousTab && row(shared, "b").inputBlock == .ambiguousTab)
    }

    @Test func aFolderNoTabIsInAndASessionWithoutAFolderAreJustUnconfirmed() async throws {
        let fake = FakeGhostty()
        fake.tabs([tab("T1", "/Users/me/elsewhere")])
        let model = make(["a": agent(100), "b": agent(200)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj")], fake: fake)
        await settle(model)
        #expect(try row(model, "a").inputBlock == .unconfirmed && row(model, "b").inputBlock == .unconfirmed)
        // The folder is the hook's own for a session of herdr's kind; here only a transcript says it, so a late one changes the answer.
        model.fixed["hooks:claude|b"] = AgentTranscript(cwd: "/Users/me/elsewhere")
        model.refresh(now: start)
        await eventually { !model.verifying }
        #expect(try row(model, "b").acceptsInput)
    }

    @Test func ghosttyThatRefusedAutomationOrFailedIsNamedAsSuch() async throws {
        let fake = FakeGhostty(.notAllowed)
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj")], fake: fake)
        await settle(model)
        #expect(try row(model, "a").inputBlock == .notAllowed("com.mitchellh.ghostty"))
        #expect(try row(model, "a").blockReason == TerminalScripts.notAllowedNote("com.mitchellh.ghostty"))
        #expect(try row(model, "a").blockReason?.contains("Ghostty") == true && !row(model, "a").acceptsInput)
        // Allowed later: the next pass lists the tabs.
        fake.tabs([tab("T1", "/Users/me/proj")])
        await settle(model)
        #expect(try row(model, "a").acceptsInput)
        fake.answer = .failed
        await settle(model)
        #expect(try row(model, "a").inputBlock == .unconfirmed)
    }

    @Test func ghosttyIsListedOncePerPassAndOnlyWhenASessionIsInIt() async throws {
        let fake = FakeGhostty()
        fake.tabs([tab("T1", "/Users/me/a"), tab("T2", "/Users/me/b"), tab("T3", "/Users/me/c")])
        let model = make(["a": agent(100), "b": agent(200), "c": agent(300)], transcripts: [
            "a": AgentTranscript(cwd: "/Users/me/a"), "b": AgentTranscript(cwd: "/Users/me/b"), "c": AgentTranscript(cwd: "/Users/me/c"),
        ], fake: fake)
        await settle(model)
        #expect(fake.listings == 1)
        await settle(model)
        #expect(fake.listings == 2)
        // None in Ghostty: in tmux (by the environment, or the tree), under another app, hooked as another terminal, or without a process.
        let none = make([
            "tmuxEnv": agent(100), "tmuxTree": agent(400), "other": agent(500), "hookedElsewhere": agent(600, app: "dev.warp.Warp-Stable"), "oldHook": agent(nil),
        ], transcripts: [:], fake: fake, environments: [100: ["TMUX": "/tmp/tmux-501/default,1,0"], 600: [:]])
        let before = fake.listings
        await settle(none)
        #expect(fake.listings == before)
        for id in ["tmuxEnv", "tmuxTree", "other", "hookedElsewhere", "oldHook"] { #expect(try row(none, id).input == nil, Comment(rawValue: id)) }
        #expect(try row(none, "tmuxEnv").inputBlock == .multiplexer)
        // The hook said Ghostty itself: still found by the tree.
        let named = make(["a": agent(100, app: "com.mitchellh.ghostty")], transcripts: ["a": AgentTranscript(cwd: "/Users/me/a")], fake: fake)
        await settle(named)
        #expect(try row(named, "a").acceptsInput)
    }

    @Test func aPlainShellIsNeverTakenForTheSessionsTab() async throws {
        // The session's tab still has its default title; a plain shell in the same folder has a title holding the session's name.
        let fake = FakeGhostty(), sent = Sent()
        fake.tabs([tab("T1", "/Users/me/Nunsseop-terms", "✳ Claude Code"), tab("T2", "/Users/me/Nunsseop-terms", "~/Nunsseop-terms")])
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/Nunsseop-terms", name: "Nunsseop-terms")], fake: fake, sent: sent)
        await settle(model)
        let blocked = try row(model, "a")
        #expect(blocked.inputBlock == .ambiguousTab && !blocked.acceptsInput && !model.send(message: "hi", to: blocked) && sent.plans.isEmpty)
        // The only tab in the folder is a dev server's shell, and the session's own tab reports another folder.
        fake.tabs([tab("T1", "/Users/me/proj", "✳ Fix login"), tab("T2", "/Users/me/proj/web", "npm run dev")])
        let lone = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj/web", name: "Fix login")], fake: fake, sent: sent)
        await settle(lone)
        #expect(try row(lone, "a").inputBlock == .unconfirmed && !row(lone, "a").acceptsInput && sent.plans.isEmpty)
        // The only tab in the folder has a Claude title, but another's holds the session's name: the folder is not to be trusted.
        fake.tabs([tab("T1", "/Users/me/proj", "✳ Fix login"), tab("T2", "/Users/me/proj/web", "◑ Review notes")])
        let drifted = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj/web", name: "Fix login")], fake: fake, sent: sent)
        await settle(drifted)
        #expect(try row(drifted, "a").inputBlock == .ambiguousTab && !row(drifted, "a").acceptsInput && sent.plans.isEmpty)
    }

    @Test func aSendThatFindsTheTabGoneLeavesANoteAndLooksAtTheTabsAgain() async throws {
        let fake = FakeGhostty(), sent = Sent()
        fake.tabs([tab("T1", "/Users/me/proj")])
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/Users/me/proj")], fake: fake, sent: sent)
        await settle(model)
        // The tab moves after the row was drawn: the handler finds it gone, and the pass that follows finds none in the folder.
        sent.passes = false
        fake.tabs([tab("T1", "/Users/me/moved")])
        #expect(model.send(message: "hi", to: try row(model, "a")))
        await eventually { model.notes["hooks:claude|a"] != nil }
        #expect(model.notes["hooks:claude|a"] == String(localized: "Couldn't send to this session"))
        await eventually { fake.listings >= 2 }
        await eventually { !model.verifying }
        #expect(try row(model, "a").inputBlock == .unconfirmed)
    }

    @Test func aSessionWhoseFolderTheTabListSpellsDifferentlyIsStillFound() async throws {
        let fake = FakeGhostty()
        fake.tabs([tab("T1", "/private/var/folders/ab/T/proj/")])
        let model = make(["a": agent(100)], transcripts: ["a": AgentTranscript(cwd: "/var/folders/ab/T/proj")], fake: fake)
        await settle(model)
        #expect(try row(model, "a").acceptsInput)
    }
}

struct GhosttyReasonTests {
    @Test func theAmbiguousTabHasItsOwnSentenceInEveryLanguage() throws {
        let key = "There are several Ghostty tabs in this folder, so Nunsseop can't tell which one"
        #expect(AgentRow.InputBlock.ambiguousTab.message == String(localized: "There are several Ghostty tabs in this folder, so Nunsseop can't tell which one"))
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            let text = table[key] as? String ?? ""
            #expect(!text.isEmpty && text != key && text.contains("Ghostty"), Comment(rawValue: language))
        }
        let ko = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("ko.lproj/Localizable.strings").path))
        #expect(ko[key] as? String == "이 폴더에 Ghostty 탭이 여러 개라 어느 탭인지 알 수 없어요")
    }

    @Test func aDeniedGhosttyReadsAsTheAutomationNote() {
        #expect(AgentRow.InputBlock.notAllowed("com.mitchellh.ghostty").message == TerminalScripts.notAllowedNote("com.mitchellh.ghostty"))
    }

    @Test func aGhosttyRowIsOfferedOnlyOnceItsTabIsFound() {
        let agent = AgentBoard.Agent(state: .working, since: start, tool: "claude", input: .ghostty(cwd: "/p", name: nil), pid: 100)
        let entry = AgentBoard.Entry(source: "hooks:claude", id: "a", agent: agent)
        #expect(!AgentRow(entry, transcript: nil, inputVerified: false).offersInput)
        #expect(AgentRow(entry, transcript: nil, inputVerified: true).acceptsInput)
    }
}
