import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Nunsseop

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func combo(_ code: Int, _ modifiers: Int, _ key: String) -> HotKeyCombo {
    HotKeyCombo(keyCode: UInt32(code), modifiers: UInt32(modifiers), key: key)
}

@Suite(.serialized)
struct ShortcutStorageTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let scratch = ScratchDefaults("Shortcuts")
        defer { scratch.remove() }
        try body(scratch.defaults)
    }

    @Test func aSearchShortcutSavedBeforeIsReadUnchanged() {
        withDefaults { defaults in
            defaults.set(40, forKey: "searchHotKeyCode")
            defaults.set(256, forKey: "searchHotKeyModifiers")
            defaults.set("K", forKey: "searchHotKeyName")
            defaults.set(true, forKey: "searchHotkey")
            let saved = combo(40, 256, "K")
            #expect(AppSettings.loadSearchHotKey(from: defaults) == saved)
            #expect(ShortcutAction.search.loadCombo(from: defaults) == saved)
            #expect(AppSettings.load("searchHotkey", default: true, from: defaults))
            // Nothing else has a shortcut because of it.
            #expect(ShortcutAction.loadOthers(from: defaults).isEmpty)
        }
    }

    @Test func searchStillKeepsItsDefaultAndTheNewActionsStartEmpty() {
        withDefaults { defaults in
            #expect(AppSettings.loadSearchHotKey(from: defaults) == .defaultSearch)
            #expect(HotKeyCombo.defaultSearch.label == "⇧⌘Space")
            #expect(AppSettings.load("searchHotkey", default: true, from: defaults))
            #expect(ShortcutAction.loadOthers(from: defaults).isEmpty)
            for action in ShortcutAction.allCases where action != .search {
                #expect(action.loadCombo(from: defaults) == nil, Comment(rawValue: action.rawValue))
            }
        }
    }

    @Test func searchIsSavedUnderTheKeysItAlwaysWas() {
        withDefaults { defaults in
            ShortcutAction.search.saveCombo(combo(kVK_ANSI_J, cmdKey | optionKey, "J"), to: defaults)
            #expect(defaults.integer(forKey: "searchHotKeyCode") == kVK_ANSI_J)
            #expect(defaults.integer(forKey: "searchHotKeyModifiers") == cmdKey | optionKey)
            #expect(defaults.string(forKey: "searchHotKeyName") == "J")
            #expect(AppSettings.loadSearchHotKey(from: defaults) == combo(kVK_ANSI_J, cmdKey | optionKey, "J"))
        }
    }

    @Test func eachOtherActionKeepsItsOwnShortcutAndForgetsItWhenCleared() {
        withDefaults { defaults in
            let first = combo(kVK_ANSI_A, controlKey | optionKey | cmdKey, "A")
            let second = combo(kVK_F5, 0, "F5")
            ShortcutAction.waitingAgent.saveCombo(first, to: defaults)
            ShortcutAction.notch.saveCombo(second, to: defaults)
            #expect(ShortcutAction.loadOthers(from: defaults) == [.waitingAgent: first, .notch: second])
            #expect(AppSettings.loadSearchHotKey(from: defaults) == .defaultSearch)
            ShortcutAction.waitingAgent.saveCombo(nil, to: defaults)
            #expect(ShortcutAction.loadOthers(from: defaults) == [.notch: second])
            #expect(defaults.object(forKey: "waitingAgentHotKeyCode") == nil && defaults.object(forKey: "waitingAgentHotKeyName") == nil)
        }
    }

    @Test func aZeroKeyCodeIsASavedShortcutNotAnEmptyOne() {
        // The A key is code 0.
        withDefaults { defaults in
            ShortcutAction.agentsTab.saveCombo(combo(kVK_ANSI_A, cmdKey, "A"), to: defaults)
            #expect(ShortcutAction.agentsTab.loadCombo(from: defaults) == combo(0, cmdKey, "A"))
        }
    }

    @Test func searchAnswersOnlyWhileItsSwitchIsOn() {
        let search = HotKeyCombo.defaultSearch, other = combo(kVK_ANSI_N, cmdKey | shiftKey, "N")
        #expect(ShortcutAction.active(searchEnabled: true, search: search, others: [.notch: other]) == [.search: search, .notch: other])
        #expect(ShortcutAction.active(searchEnabled: false, search: search, others: [.notch: other]) == [.notch: other])
    }
}

struct ShortcutAssignmentTests {
    private let space = HotKeyCombo.defaultSearch
    private let mine = combo(kVK_ANSI_A, controlKey | optionKey | cmdKey, "A")

    @Test func aCombinationAnotherActionUsesIsRefusedAndNamesThatAction() {
        let active: [ShortcutAction: HotKeyCombo] = [.search: space, .waitingAgent: mine]
        #expect(ShortcutAction.assignment(of: space, to: .notch, active: active) == .takenBy(.search))
        #expect(ShortcutAction.assignment(of: mine, to: .agentsTab, active: active) == .takenBy(.waitingAgent))
        #expect(ShortcutAction.assignment(of: mine, to: .search, active: active) == .takenBy(.waitingAgent))
    }

    @Test func aFreeCombinationOrTheActionsOwnIsSaved() {
        let active: [ShortcutAction: HotKeyCombo] = [.search: space, .waitingAgent: mine]
        #expect(ShortcutAction.assignment(of: combo(kVK_ANSI_B, cmdKey, "B"), to: .notch, active: active) == .saved)
        #expect(ShortcutAction.assignment(of: mine, to: .waitingAgent, active: active) == .saved)
        // The same key with other modifiers is another combination.
        #expect(ShortcutAction.assignment(of: combo(kVK_ANSI_A, cmdKey, "A"), to: .notch, active: active) == .saved)
    }

    @Test func searchSwitchedOffDoesNotHoldItsCombination() {
        let active = ShortcutAction.active(searchEnabled: false, search: space, others: [:])
        #expect(ShortcutAction.assignment(of: space, to: .notch, active: active) == .saved)
    }

    @Test func theKeyNameDoesNotMatterOnlyTheKeysDo() {
        let active: [ShortcutAction: HotKeyCombo] = [.notch: combo(kVK_ANSI_A, cmdKey, "A")]
        #expect(ShortcutAction.assignment(of: combo(kVK_ANSI_A, cmdKey, "a"), to: .agentsTab, active: active) == .takenBy(.notch))
    }
}

struct ShortcutStepTests {
    @Test func searchAndTheAgentsTabOpenTheirTabAndCloseTheNotchWhenPressedOnIt() {
        #expect(ShortcutAction.search.step(expanded: false, tab: .home) == .open(.search, focusSearch: true))
        #expect(ShortcutAction.search.step(expanded: true, tab: .shelf) == .open(.search, focusSearch: true))
        #expect(ShortcutAction.search.step(expanded: true, tab: .search) == .collapse)
        #expect(ShortcutAction.agentsTab.step(expanded: false, tab: .home) == .open(.agents, focusSearch: false))
        #expect(ShortcutAction.agentsTab.step(expanded: true, tab: .search) == .open(.agents, focusSearch: false))
        #expect(ShortcutAction.agentsTab.step(expanded: true, tab: .agents) == .collapse)
        // Each closes the notch only on its own tab.
        #expect(ShortcutAction.search.step(expanded: true, tab: .agents) != .collapse)
    }

    @Test func theNotchShortcutKeepsTheTabItIsOn() {
        #expect(ShortcutAction.notch.step(expanded: false, tab: .notes) == .open(nil, focusSearch: false))
        #expect(ShortcutAction.notch.step(expanded: true, tab: .notes) == .collapse)
    }

    @Test func theOtherTwoLeaveTheLookUpToTheCaller() {
        for expanded in [false, true] {
            #expect(ShortcutAction.waitingAgent.step(expanded: expanded, tab: .home) == .goToWaitingAgent)
            #expect(ShortcutAction.lastNotice.step(expanded: expanded, tab: .agents) == .goToLastNotice)
        }
    }
}

private func row(_ id: String, _ state: AgentBoard.State, since: Date?, app: String? = nil) -> AgentRow {
    AgentRow(AgentBoard.Entry(source: "hooks:claude", id: id, agent: AgentBoard.Agent(state: state, since: since, tool: "claude", app: app)), transcript: nil)
}

private final class Activations: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [String] = []
    var list: [String] { lock.withLock { apps } }
    var focuser: AgentFocuser {
        AgentFocuser(run: { _ in .sent }, activate: { [self] app in lock.withLock { apps.append(app) } }, herdr: { _, _ in })
    }
}

@MainActor
struct WaitingAgentTests {
    @Test func theSessionThatHasWaitedLongestIsChosen() {
        let rows = [row("new", .waiting, since: start.addingTimeInterval(-60)), row("busy", .working, since: start.addingTimeInterval(-9_000)),
                    row("old", .waiting, since: start.addingTimeInterval(-600)), row("idle", .idle, since: start.addingTimeInterval(-90_000))]
        #expect(AgentsTabModel.longestWaiting(in: rows)?.id == "hooks:claude|old")
    }

    @Test func aWaitingSessionThatSaysNotSinceWhenComesAfterOneThatDoes() {
        let rows = [row("unknown", .waiting, since: nil), row("known", .waiting, since: start)]
        #expect(AgentsTabModel.longestWaiting(in: rows)?.id == "hooks:claude|known")
        #expect(AgentsTabModel.longestWaiting(in: [row("unknown", .waiting, since: nil)])?.id == "hooks:claude|unknown")
    }

    @Test func nobodyWaitingChoosesNobody() {
        #expect(AgentsTabModel.longestWaiting(in: []) == nil)
        #expect(AgentsTabModel.longestWaiting(in: [row("a", .working, since: start), row("b", .idle, since: start)]) == nil)
    }

    private func model(_ agents: [String: AgentBoard.Agent], activations: Activations) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "hooks:claude", with: agents, now: start)
        let model = AgentsTabModel(board: board, home: { URL(fileURLWithPath: "/nonexistent-home") }, isConnected: { true }, scratch: [],
                                   sender: AgentSender { _ in .failed }, focuser: activations.focuser)
        model.fixedRecent = []
        return model
    }

    @Test func theShortcutGoesToTheLongestWaitingSessionWithoutTheTabShowing() {
        let activations = Activations()
        let model = model(["a": .init(state: .waiting, since: start.addingTimeInterval(-60), tool: "claude", app: "com.apple.Terminal"),
                           "b": .init(state: .waiting, since: start.addingTimeInterval(-900), tool: "claude", app: "com.mitchellh.ghostty"),
                           "c": .init(state: .working, since: start.addingTimeInterval(-9_000), tool: "claude", app: "com.googlecode.iterm2")],
                          activations: activations)
        #expect(model.rows.isEmpty && !model.isShowing)
        #expect(model.focusLongestWaiting(now: start))
        #expect(activations.list == ["com.mitchellh.ghostty"])
    }

    @Test func withNobodyWaitingTheShortcutSaysSoAndGoesNowhere() {
        let activations = Activations()
        let model = model(["a": .init(state: .working, since: start, tool: "claude", app: "com.apple.Terminal")], activations: activations)
        #expect(!model.focusLongestWaiting(now: start))
        #expect(activations.list.isEmpty)
    }
}

@MainActor
struct LastNoticeTests {
    @Test func theNewestNoticeWithAnActionIsTheOneToGoBackTo() {
        let log = NoticeLog()
        var ran: [String] = []
        log.add(symbol: "terminal", title: "older", detail: nil, action: { ran.append("older") }, at: start)
        log.add(symbol: "terminal", title: "newer", detail: nil, action: { ran.append("newer") }, at: start.addingTimeInterval(10))
        log.add(symbol: "calendar", title: "no way back", detail: nil, at: start.addingTimeInterval(20))
        let entry = log.latestWithAction
        #expect(entry?.title == "newer")
        entry?.action?()
        #expect(ran == ["newer"])
    }

    @Test func noNoticeWithAnActionMeansNothingToGoBackTo() {
        let log = NoticeLog()
        #expect(log.latestWithAction == nil)
        log.add(symbol: "calendar", title: "Lunch", detail: nil)
        #expect(log.latestWithAction == nil)
    }
}

struct ShortcutTranslationTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }

    @Test func everyNewSentenceIsTranslatedIntoEveryLanguage() throws {
        let keys = ["Open Search in the notch", "Go to the agent that waits", "Brings the terminal of the session that has waited longest to the front",
                    "Open the Agents tab", "Go to where the last notice came from", "Open or close the notch", "Shortcuts", "Record shortcut",
                    "Remove shortcut", "No agent is waiting", "No notice to go back to",
                    "New actions start empty. You'll be told when another app already uses a combination.",
                    "Already used by “%@”. Pick a different combination."]
        let placeholders = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for (key, count) in zip(keys, placeholders) {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                #expect(text.components(separatedBy: "%@").count - 1 == count, Comment(rawValue: "\(language): \(key)"))
            }
        }
    }

    @Test func theKoreanLabelsAreTheApprovedOnes() throws {
        let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("ko.lproj/Localizable.strings").path))
        #expect(table["Open Search in the notch"] as? String == "노치에서 검색 열기")
        #expect(table["Go to the agent that waits"] as? String == "기다리는 에이전트로 가기")
        #expect(table["Brings the terminal of the session that has waited longest to the front"] as? String == "가장 오래 기다린 세션의 터미널을 앞으로")
        #expect(table["Open the Agents tab"] as? String == "에이전트 탭 열기")
        #expect(table["Go to where the last notice came from"] as? String == "마지막 알림이 온 곳으로 가기")
        #expect(table["Open or close the notch"] as? String == "노치 열고 닫기")
        #expect(table["New actions start empty. You'll be told when another app already uses a combination."] as? String == "새로 생긴 동작은 비워 둡니다. 다른 앱이 이미 쓰는 조합이면 알려 드려요.")
    }
}
