import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Nunsseop

/// A done flag that lives in a scratch suite.
private func withDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "NunsseopTests.Onboarding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try body(defaults)
}

/// A tour over made-up tools; `connect` stands in for connecting them.
@MainActor
private func makeTour(_ defaults: UserDefaults, tools: [NotifyIntegration] = [],
                      connected: Set<NotifyIntegration> = [],
                      connect: @escaping (NotifyIntegration) throws -> Void = { _ in }) -> OnboardingTour {
    OnboardingTour(defaults: defaults, presentTools: { tools }, isConnected: { connected.contains($0) },
                   connectTool: connect, hasBackup: { _ in false })
}

// MARK: - When it runs

struct OnboardingFirstRunTests {
    @Test(arguments: [(true, false, true), (true, true, false), (false, false, false), (false, true, false)])
    func theTourRunsOnlyOnAFreshInstallThatHasNotDoneIt(fresh: Bool, done: Bool, runs: Bool) {
        withDefaults { defaults in
            if done { defaults.set(true, forKey: OnboardingTour.doneKey) }
            #expect(OnboardingTour.shouldStart(freshInstall: fresh, defaults: defaults) == runs)
        }
    }

    @Test func theDoneFlagIsStoredUnderItsDocumentedKey() {
        #expect(OnboardingTour.doneKey == "onboardingDone")
    }

    @Test func aFreshInstallHasNoNotifyTokenYetAndTheServerMakesOne() throws {
        try withTempHome { _ in
            #expect(OnboardingTour.isFreshInstall())
            // The view model's server creates the token, which is why the window controller asks before building it.
            _ = NotifyServer(port: 0)
            #expect(!OnboardingTour.isFreshInstall())
        }
    }

    @Test func aFileNamedByTheCallerDecides() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(OnboardingTour.isFreshInstall(tokenFile: file))
        try Data("x".utf8).write(to: file)
        #expect(!OnboardingTour.isFreshInstall(tokenFile: file))
    }

    @MainActor @Test func preparingMarksTheTourPendingOnlyWhenItShouldRun() {
        withDefaults { defaults in
            let upgrade = makeTour(defaults)
            upgrade.prepare(freshInstall: false)
            #expect(!upgrade.isPending && !upgrade.isActive)

            let fresh = makeTour(defaults)
            fresh.prepare(freshInstall: true)
            #expect(fresh.isPending && !fresh.isActive)
            fresh.start()
            #expect(!fresh.isPending && fresh.isActive)
        }
    }

    @MainActor @Test func aFinishedTourIsNotPendingAgainOnTheNextLaunch() {
        withDefaults { defaults in
            let first = makeTour(defaults)
            first.prepare(freshInstall: true)
            first.start()
            first.skip()
            let second = makeTour(defaults)
            second.prepare(freshInstall: true)
            #expect(!second.isPending)
        }
    }

    @Test(arguments: [(true, false, false, true), (false, false, false, false), (true, true, false, false), (true, false, true, false)])
    func itWaitsForAPromptOrANoticeToBeClickedAndForAVisiblePanel(visible: Bool, approval: Bool, notice: Bool, begins: Bool) {
        #expect(OnboardingTour.canBegin(panelVisible: visible, approvalShowing: approval, noticeClickable: notice) == begins)
    }

    @MainActor @Test func aPermissionCardKeepsTheTourOffTheNotchAndItComesBackAfter() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            tour.next()
            let board = PermissionBoard()
            board.add(PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: "ls", folder: "proj", grant: nil))
            #expect(!OnboardingTour.canBegin(panelVisible: true, approvalShowing: board.current != nil, noticeClickable: false))
            #expect(!tour.shows(expanded: true, approvalShowing: board.current != nil))
            board.clear()
            #expect(tour.shows(expanded: true, approvalShowing: board.current != nil))
            #expect(tour.index == 1)
        }
    }
}

// MARK: - Steps

@MainActor
struct OnboardingStepTests {
    @Test func theLastStepOffersToolsWhenThereAreSomeAndSaysItIsDoneWhenThereAreNone() {
        #expect(OnboardingTour.steps(hasTools: true) == [.opening, .tabs, .filesAndSearch, .agents])
        #expect(OnboardingTour.steps(hasTools: false) == [.opening, .tabs, .filesAndSearch, .ready])
        #expect(OnboardingTour.stepCount == 4)
    }

    @Test func aTourWalksTheStepsOnceAndFinishesAfterTheLast() {
        withDefaults { defaults in
            let tour = makeTour(defaults, tools: [.claudeCode])
            tour.start()
            #expect(tour.index == 0 && tour.step == .opening)
            var seen = [tour.step]
            while !tour.isLast { tour.next(); seen.append(tour.step) }
            #expect(seen == [.opening, .tabs, .filesAndSearch, .agents])
            #expect(tour.isActive)
            tour.next()
            #expect(!tour.isActive)
            #expect(defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func withoutToolsTheFourthStepIsTheReadyOneAndNeverBoth() {
        withDefaults { defaults in
            let none = makeTour(defaults)
            none.start()
            #expect(none.rows.isEmpty && none.steps.last == .ready && !none.steps.contains(.agents))
            let some = makeTour(defaults, tools: [.claudeCode, .codex])
            some.start()
            #expect(some.rows.map(\.tool) == [.claudeCode, .codex] && some.steps.last == .agents && !some.steps.contains(.ready))
            #expect(none.steps.count == 4 && some.steps.count == 4)
        }
    }

    @Test func aToolThatIsAlreadyConnectedStartsConnected() {
        withDefaults { defaults in
            let tour = makeTour(defaults, tools: [.claudeCode, .codex], connected: [.claudeCode])
            tour.start()
            #expect(tour.rows.map(\.state) == [.connected, .idle])
        }
    }

    @Test func backGoesBackOnlyAsFarAsTheFirstStep() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            tour.back()
            #expect(tour.index == 0)
            tour.next(); tour.next()
            tour.back()
            #expect(tour.index == 1)
        }
    }

    @Test func nothingMovesWhileTheTourIsNotRunning() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.next()
            tour.back()
            #expect(!tour.isActive && tour.index == 0)
            #expect(!defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func theToolsOfThisMacComeFromTheirFoldersAndSettleTheLastStep() throws {
        try withTempHome { home in
            let fileManager = FileManager.default
            try withDefaults { defaults in
                let tour = OnboardingTour(defaults: defaults)
                tour.start()
                #expect(tour.steps.last == .ready)

                try fileManager.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
                tour.start()
                #expect(tour.rows.map(\.tool) == [.codex] && tour.steps.last == .agents)
            }
        }
    }

    @Test func theCopyOfTheFirstStepFollowsTheDisplayAndThePillsFading() {
        let notch = OnboardingText.opening(hasNotch: true, hideAfter: 8)
        let pill = OnboardingText.opening(hasNotch: false, hideAfter: 8)
        #expect(notch.text != pill.text && notch.note != pill.note)
        #expect(pill.note?.contains("8") == true)
        // A pill that never fades has nothing to say about it.
        #expect(OnboardingText.opening(hasNotch: false, hideAfter: nil).note == nil)
        #expect(OnboardingText.ready(hasNotch: true) != OnboardingText.ready(hasNotch: false))
    }

    @Test func theFilesStepLeavesTheSearchOutWhenItsShortcutIsOff() {
        let both = OnboardingText.files(showsSearch: true), filesOnly = OnboardingText.files(showsSearch: false)
        #expect(both.title != filesOnly.title && both.text != filesOnly.text)
    }

    @Test func theShortcutIsShownAsTheKeysToPress() {
        #expect(OnboardingTour.keycaps(for: .defaultSearch) == ["⇧", "⌘", "Space"])
        #expect(OnboardingTour.keycaps(for: HotKeyCombo(keyCode: UInt32(kVK_F5), modifiers: UInt32(controlKey | optionKey), key: "F5"))
                == ["⌃", "⌥", "F5"])
        #expect(OnboardingTour.keycaps(for: HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey), key: "A")) == ["⌘", "A"])
    }
}

// MARK: - Finishing, skipping, leaving, coming back

@MainActor
struct OnboardingProgressTests {
    @Test func skippingAndFinishingBothSetTheFlagAndEndTheTour() {
        for ends in [{ (tour: OnboardingTour) in tour.skip() }, { (tour: OnboardingTour) in tour.finish() }] {
            withDefaults { defaults in
                let tour = makeTour(defaults)
                tour.start()
                tour.next()
                #expect(!defaults.bool(forKey: OnboardingTour.doneKey))
                ends(tour)
                #expect(defaults.bool(forKey: OnboardingTour.doneKey) && !tour.isActive)
            }
        }
    }

    @Test func closingTheNotchMidwayDoesNotFinishItAndTheSameStepIsThereOnReopening() {
        withDefaults { defaults in
            let tour = makeTour(defaults, tools: [.codex])
            tour.start()
            tour.next(); tour.next()
            #expect(tour.shows(expanded: true, approvalShowing: false))
            // The notch closes (a click elsewhere): the tour isn't asked anything, and shows nothing while closed.
            #expect(!tour.shows(expanded: false, approvalShowing: false))
            #expect(tour.isActive && !defaults.bool(forKey: OnboardingTour.doneKey))
            // Hovering opens it again, on the step it was on.
            #expect(tour.shows(expanded: true, approvalShowing: false) && tour.step == .filesAndSearch && tour.index == 2)
        }
    }

    @Test func aFinishedTourShowsNothingEvenInAnOpenNotch() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            tour.skip()
            #expect(!tour.shows(expanded: true, approvalShowing: false))
        }
    }

    @Test func replayingStartsFromTheFirstStepWhateverTheFlagSaysAndSetsItAgain() {
        withDefaults { defaults in
            let tour = makeTour(defaults, tools: [.claudeCode])
            tour.start()
            tour.next(); tour.next()
            tour.skip()
            #expect(defaults.bool(forKey: OnboardingTour.doneKey))

            tour.start()
            #expect(tour.isActive && tour.index == 0)
            tour.next()
            defaults.removeObject(forKey: OnboardingTour.doneKey)
            tour.skip()
            #expect(defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func replayingMidwayGoesBackToTheFirstStep() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            tour.next(); tour.next()
            tour.start()
            #expect(tour.index == 0)
        }
    }

    @Test func theSettingsButtonClosesSettingsAndAsksTheNotchToReplay() {
        let settings = SettingsWindowController.shared
        let before = settings.onReplayTour
        defer { settings.onReplayTour = before }
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            tour.next(); tour.next()
            settings.onReplayTour = { tour.start() }
            settings.replayTour()
            #expect(tour.index == 0 && tour.isActive)
        }
    }
}

// MARK: - Keys and the pointer

@MainActor
struct OnboardingKeyTests {
    @Test(arguments: [(53, OnboardingTour.Command.skip), (36, .next), (76, .next), (124, .next), (123, .back)])
    func keysMapToTheTourCommands(keyCode: Int, command: OnboardingTour.Command) {
        #expect(OnboardingTour.command(keyCode: UInt16(keyCode), modifiers: []) == command)
    }

    @Test func otherKeysAndKeysWithAModifierAreLeftAlone() {
        #expect(OnboardingTour.command(keyCode: 0, modifiers: []) == nil)
        #expect(OnboardingTour.command(keyCode: 125, modifiers: []) == nil)
        for flag: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            #expect(OnboardingTour.command(keyCode: 53, modifiers: flag) == nil)
            #expect(OnboardingTour.command(keyCode: 36, modifiers: flag) == nil)
        }
    }

    @Test func escapeSkipsReturnAdvancesAndTheArrowsMove() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            @MainActor func press(_ code: UInt16) {
                if let command = OnboardingTour.command(keyCode: code, modifiers: []) { tour.perform(command) }
            }
            press(36)
            press(124)
            #expect(tour.index == 2)
            press(123)
            #expect(tour.index == 1)
            press(53)
            #expect(!tour.isActive && defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func returnOnTheLastStepFinishes() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.start()
            for _ in 0..<3 { tour.perform(.next) }
            #expect(tour.isLast && tour.isActive)
            tour.perform(.next)
            #expect(!tour.isActive && defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func theTourHoldsTheNotchOpenWhereverThePointerGoes() {
        // Not pinned, because the pointer has visited it: a notch opened by hovering is not held open, the tour's is.
        #expect(OpenNotchHold.of(composing: false, touring: true, pinned: false) == .touring)
        #expect(OpenNotchHold.of(composing: false, touring: true, pinned: true) == .touring)
        #expect(OpenNotchHold.of(composing: false, touring: false, pinned: false) == .followsPointer)
    }

    @Test func aMessageBeingTypedAndAShortcutKeepTheirOwnRules() {
        #expect(OpenNotchHold.of(composing: true, touring: true, pinned: true) == .composing)
        #expect(OpenNotchHold.of(composing: false, touring: false, pinned: true) == .pinned)
    }
}

// MARK: - Connecting tools

@MainActor
struct OnboardingConnectTests {
    @Test func connectingCallsTheInstallAndShowsConnected() {
        withDefaults { defaults in
            var installed: [NotifyIntegration] = []
            let tour = makeTour(defaults, tools: [.claudeCode, .codex]) { installed.append($0) }
            tour.start()
            tour.connect(.codex)
            #expect(installed == [.codex])
            #expect(tour.rows.map(\.state) == [.idle, .connected])
        }
    }

    @Test func aFailureShowsWhichFileCouldNotBeChangedAndRetryingCanSucceed() throws {
        try withTempHome { _ in
            withDefaults { defaults in
                var failing = true
                let tour = makeTour(defaults, tools: [.claudeCode, .codex]) { tool in
                    if failing { throw tool == .codex ? NotifyIntegration.IntegrationError.unreadableHooks : .unreadableConfig }
                }
                tour.start()
                tour.connect(.claudeCode)
                tour.connect(.codex)
                // The same file Settings names.
                #expect(tour.rows.map(\.state) == [.failed(NotifyIntegration.claudeCode.configURL), .failed(NotifyIntegration.codex.hooksURL)])

                failing = false
                tour.connect(.codex)
                #expect(tour.rows.map(\.state) == [.failed(NotifyIntegration.claudeCode.configURL), .connected])
            }
        }
    }

    @Test func aToolThatIsNotInTheListIsIgnored() {
        withDefaults { defaults in
            var installed = 0
            let tour = makeTour(defaults, tools: [.claudeCode]) { _ in installed += 1 }
            tour.start()
            tour.connect(.gemini)
            #expect(installed == 0 && tour.rows.map(\.state) == [.idle])
        }
    }

    @Test func theDefaultConnectionIsTheOneSettingsUsesAndKeepsTheOldFile() throws {
        try withTempHome { _ in
            let fileManager = FileManager.default
            let config = NotifyIntegration.claudeCode.configURL
            try fileManager.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"model":"opus"}"#.utf8).write(to: config)

            withDefaults { defaults in
                let tour = OnboardingTour(defaults: defaults)
                tour.start()
                #expect(tour.rows.map(\.tool) == [.claudeCode] && tour.rows.map(\.state) == [.idle])
                tour.connect(.claudeCode)
                #expect(tour.rows.map(\.state) == [.connected] && tour.rows[0].backedUp)
            }
            #expect(NotifyIntegration.claudeCode.isInstalled)
            #expect(fileManager.fileExists(atPath: config.appendingPathExtension("nunsseop-backup").path))
        }
    }

    @Test func eachRowSaysWhereItStands() {
        let idle = OnboardingTour.ToolRow(tool: .claudeCode, state: .idle)
        let codex = OnboardingTour.ToolRow(tool: .codex, state: .idle)
        #expect(OnboardingView.note(for: idle, notificationsOn: true).text == OnboardingText.notConnected)
        #expect(OnboardingView.note(for: codex, notificationsOn: true).text == OnboardingText.trustHooks)
        #expect(OnboardingView.note(for: idle, notificationsOn: false).text == OnboardingText.notificationsOff)

        let connected = OnboardingTour.ToolRow(tool: .claudeCode, state: .connected)
        var backedUp = connected
        backedUp.backedUp = true
        #expect(OnboardingView.note(for: connected, notificationsOn: true).text == OnboardingText.connected)
        #expect(OnboardingView.note(for: backedUp, notificationsOn: true).text == OnboardingText.connectedBackedUp)
        #expect(OnboardingView.note(for: OnboardingTour.ToolRow(tool: .codex, state: .connected), notificationsOn: true).text
                == OnboardingText.connectedTrust)

        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        let failed = OnboardingView.note(for: OnboardingTour.ToolRow(tool: .claudeCode, state: .failed(file)), notificationsOn: true)
        #expect(failed.failed && failed.text.contains("settings.json") && failed.detail == "~/.claude/settings.json")
    }
}

// MARK: - Layout

struct OnboardingMetricsTests {
    @Test func theColumnsFillTheNotchAndTheFrameFillsItsHeight() {
        let size = OnboardingTour.minimumSize
        #expect(OnboardingMetrics.copyWidth + OnboardingMetrics.rowGap + OnboardingMetrics.visualWidth == size.width - 2 * NotchViewModel.headerInset)
        // Band, the gap under it, the content, 8 clear above the footer's buttons, the buttons and the notch's bottom padding.
        #expect(OnboardingMetrics.minimumBand + OnboardingMetrics.bandGap + OnboardingMetrics.contentHeight + 8
                + OnboardingMetrics.buttonHeight + 16 == size.height)
    }

    @Test func aTallerCameraHousingGrowsTheNotchByTheBandsExtraHeight() {
        #expect(OnboardingTour.minimumFrame(notchHeight: 32) == OnboardingTour.minimumSize)
        #expect(OnboardingTour.minimumFrame(notchHeight: 18) == OnboardingTour.minimumSize)
        #expect(OnboardingTour.minimumFrame(notchHeight: 37) == CGSize(width: 620, height: 201))
        #expect(OnboardingTour.band(notchHeight: 37) == 37 && OnboardingTour.band(notchHeight: 24) == 32)
    }

    @Test func twoRowsAndTheHintFitTheContent() {
        let rows = 2 * OnboardingMetrics.rowHeight + OnboardingMetrics.rowGap
        // The hint is one line of 11 points. Two tools, or one tool and the login row, are two rows.
        #expect(rows + OnboardingMetrics.rowGap + 14 <= OnboardingMetrics.contentHeight)
    }

    @Test func aRowOfTabsAndItsHintFit() {
        let tabs = 2 * (22 + 3 + 13) + OnboardingMetrics.tabRowGap
        #expect(tabs + OnboardingMetrics.rowGap + 14 <= OnboardingMetrics.contentHeight)
        #expect(OnboardingMetrics.tabsPerRow * 2 >= NotchTab.allCases.count)
    }
}

// MARK: - Translations

private enum Translations {
    static let languages = ["de", "es", "fr", "ja", "ko", "zh-Hans"]

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func table(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], Comment(rawValue: language))
    }

    static func text(_ language: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings"), encoding: .utf8)
    }

    /// Every sentence the tour can say: the keys written in OnboardingText.
    static func keys() throws -> [String] {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Nunsseop/OnboardingText.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        return pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
    }

    /// The placeholders of a string, without their positions.
    static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll)?[d@]"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }
}

struct OnboardingTranslationTests {
    @Test func theTourSaysAGoodManySentencesAndEachIsKeyedOnce() throws {
        let keys = try Translations.keys()
        #expect(keys.count == Set(keys).count)
        #expect(keys.count > 40)
    }

    @Test(arguments: Translations.languages)
    func everySentenceIsTranslatedDifferentlyWithTheSamePlaceholders(language: String) throws {
        let table = try Translations.table(language)
        for key in try Translations.keys() {
            let value = try #require(table[key], Comment(rawValue: "\(language): \(key)"))
            #expect(!value.isEmpty && value != key, Comment(rawValue: "\(language): \(key)"))
            #expect(Translations.placeholders(value) == Translations.placeholders(key), Comment(rawValue: "\(language): \(key)"))
        }
    }

    @Test(arguments: Translations.languages)
    func noFileHasAKeyTwice(language: String) throws {
        let text = try Translations.text(language)
        let pattern = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)" = "#, options: .anchorsMatchLines)
        let keys = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) }
        #expect(Dictionary(grouping: keys, by: { $0 }).filter { $1.count > 1 }.keys.sorted() == [])
    }

    @Test(arguments: Translations.languages + ["en"])
    func noExclamationMarksAndNoEmoji(language: String) throws {
        let table = language == "en" ? [:] : try Translations.table(language)
        for key in try Translations.keys() {
            let value = table[key] ?? key
            #expect(!value.contains("!") && !value.contains("！"), Comment(rawValue: "\(language): \(value)"))
            #expect(!value.unicodeScalars.contains { $0.properties.isEmojiPresentation }, Comment(rawValue: "\(language): \(value)"))
        }
    }

    @Test func koreanSpeaksInHaeyoStyleNotInFormalEndings() throws {
        let table = try Translations.table("ko")
        let reused: Set = ["Next", "Connect", "Allow Nunsseop in System Settings › General › Login Items.",
                           "Move the app to /Applications before turning this on. Current location: %@"]
        for key in try Translations.keys() where !reused.contains(key) {
            let value = try #require(table[key])
            #expect(!value.contains("니다"), Comment(rawValue: value))
        }
        #expect(table["Welcome tour"] == "시작 안내")
        #expect(table["Show the welcome tour again"] == "시작 안내 다시 보기")
    }

    @Test func theStepIsAnnouncedAsInTheDesign() throws {
        let ko = try Translations.table("ko")
        #expect(String(format: try #require(ko["Step %lld of %lld"]), 2, 4) == "4단계 중 2단계")
        #expect(OnboardingText.stepLabel(2, of: 4) == "Step 2 of 4")
    }

    /// The names a sentence points at are the app's own, as each language already calls them.
    @Test(arguments: Translations.languages)
    func sentencesUseTheLanguagesOwnNamesForSettingsAndTheirPanes(language: String) throws {
        let table = try Translations.table(language)
        func term(_ key: String) throws -> String { try #require(table[key], Comment(rawValue: "\(language): \(key)")) }
        let settings = try term("Settings"), general = try term("General"), alerts = try term("Alerts")
        let expectations: [(String, [String])] = [
            ("Reopen this tour from Settings › General › Show the welcome tour again", [settings, general, try term("Show the welcome tour again")]),
            ("Right-click the notch › Settings… to hide or reorder tabs.", [try term("Settings…")]),
            ("Or connect later in Settings › Alerts.", [settings, alerts]),
            ("Turned off in Settings › Alerts", [settings, alerts]),
            ("On · change in Settings › General", [settings, general]),
            ("Off · change in Settings › General", [settings, general]),
            ("Tools found on this Mac are listed. Connect one to see its sessions and reply in the Agents tab.", [try term("Agents")]),
        ]
        for (key, terms) in expectations {
            let value = try term(key)
            for part in terms { #expect(value.contains(part), Comment(rawValue: "\(language): \(key) lacks \(part)")) }
        }
    }
}

// MARK: - Text that fits

/// Whether each sentence fits the room it is laid out in, in every language: measured with the fonts the view uses.
struct OnboardingFitTests {
    private static let languages = ["en"] + Translations.languages

    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    private func height(_ text: String, width: CGFloat, size: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let box = (text as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
                                                  attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style])
        return ceil(box.height)
    }

    @Test(arguments: OnboardingFitTests.languages)
    func everyPageFitsItsColumnsInEveryLanguage(language: String) throws {
        let table = language == "en" ? [:] : try Translations.table(language)
        func t(_ key: String, _ args: CVarArg...) -> String {
            let value = table[key] ?? key
            return args.isEmpty ? value : String(format: value, arguments: args)
        }
        var problems: [String] = []
        func expectFits(_ what: String, _ used: CGFloat, _ room: CGFloat, _ text: String) {
            if used > room { problems.append("\(what): \(used) > \(room) «\(text)»") }
        }

        // The copy column: title, text and note in 204 points and the content's height.
        func column(_ name: String, title: String, text: String, note: String?, check: Bool = false) {
            let titleWidth = width(title, size: 15, weight: .semibold) + (check ? 21 : 0)
            expectFits("\(name) title", titleWidth, OnboardingMetrics.copyWidth, title)
            var used = 18 + 6 + height(text, width: OnboardingMetrics.copyWidth, size: 12, lineSpacing: 2)
            if let note { used += 6 + height(note, width: OnboardingMetrics.copyWidth, size: 11, lineSpacing: 1) }
            expectFits("\(name) column", used, OnboardingMetrics.contentHeight - 2, text)
        }
        let title = t("This is Nunsseop")
        column("notch", title: title, text: t("Hover over the notch, or swipe down with two fingers, to open it. Move the pointer away to close it."),
               note: t("At first there is nothing to see."))
        column("pill", title: title, text: t("Move the pointer to the top center to open it, away to close it."),
               note: t("The pill fades after %lld seconds and returns at the top edge.", 60))
        column("tabs", title: t("Tabs are icons"), text: t("Tabs show only icons; hover over one to see its name. Here they have labels."), note: nil)
        column("files", title: t("Drop and search"), text: t("The two things you will use most."), note: nil)
        column("filesOnly", title: t("Drop files"), text: t("The quickest way to keep files at hand."), note: nil)
        column("agents", title: t("Connect your agents"),
               text: t("Tools found on this Mac are listed. Connect one to see its sessions and reply in the Agents tab."),
               note: t("Or connect later in Settings › Alerts."))
        column("ready", title: t("You're all set"), text: t("Now hover over the notch."), note: nil, check: true)
        column("readyPill", title: t("You're all set"), text: t("Now move the pointer to the top of the screen."), note: nil, check: true)

        // One line each, at the scale the view may shrink it to.
        func line(_ what: String, _ key: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, room: CGFloat, scale: CGFloat = 1, _ args: CVarArg...) {
            let text = args.isEmpty ? t(key) : String(format: table[key] ?? key, arguments: args)
            expectFits(what, width(text, size: size, weight: weight) * scale, room, text)
        }
        let visual = OnboardingMetrics.visualWidth
        line("reopen", "Reopen this tour from Settings › General › Show the welcome tour again", room: visual, scale: 0.85)
        line("tabs hint", "Right-click the notch › Settings… to hide or reorder tabs.", room: visual - 17, scale: 0.85)
        for caption in ["Closed · hover over it", "Pill · go to the top edge", "Open · leave to close"] {
            line(caption, caption, room: 152, scale: 0.85)
        }
        line("header", "Welcome tour", size: 11, weight: .medium, room: 150)
        line("login label", "Open at login", size: 12, room: 170)

        // A tool's row: what is left beside its name once the button has its width.
        let rowNoEnd: CGFloat = visual - 16 - OnboardingMetrics.iconSize - 10 - 10 - 4
        let row = rowNoEnd - 10
        let connect = width(t("Connect"), size: 12, weight: .medium) + 28
        let retry = width(t("Retry"), size: 12, weight: .medium) + 28
        line("not connected", "Not connected", room: row - connect)
        line("trust hooks", "Asks once to trust the hooks", room: row - connect)
        line("notifications off", "Turned off in Settings › Alerts", room: row - connect)
        line("couldn't change", "Couldn't change %@", room: row - retry, "settings.json")
        for key in ["Connected", "Connected · old settings backed up", "Connected · asks once to trust the hooks"] {
            line(key, key, room: rowNoEnd - 15)
        }
        // The ready step's rows: the lock row has nothing at its end, the login row a switch.
        line("permissions title", "Permissions are asked only on first use", size: 12, weight: .semibold, room: rowNoEnd)
        line("permissions text", "Calendar, screen recording and camera: when used", room: rowNoEnd)
        line("login title", "Open at login", size: 12, weight: .semibold, room: rowNoEnd - 10 - 38)
        line("login on", "On · change in Settings › General", room: rowNoEnd - 10 - 38)
        line("login off", "Off · change in Settings › General", room: rowNoEnd - 10 - 38)

        // The files step: a title beside the keys, and two lines under each.
        line("drop title", "Drag files onto the notch", size: 12, weight: .semibold, room: visual - 42)
        line("search title", "to open Search", size: 12, weight: .semibold, room: visual - 42 - 101 - 2 - 6)
        for key in ["They collect on the Shelf. Send them with AirDrop or Share; screenshots land there too.",
                    "Find apps, files, commands and emoji, and do math."] {
            expectFits(key, height(t(key), width: visual - 42, size: 11, lineSpacing: 0), 29, t(key))
        }

        // Tabs: each row of seven is spread by its labels' widths, which may shrink to 80%.
        let names = NotchTab.allCases.map { table[Self.englishTitle($0)] ?? Self.englishTitle($0) }
        for start in stride(from: 0, to: names.count, by: OnboardingMetrics.tabsPerRow) {
            let row = names[start..<min(start + OnboardingMetrics.tabsPerRow, names.count)]
            let total = row.map { max(30, width($0, size: 11) * 0.8) }.reduce(0, +) + 6 * CGFloat(row.count - 1)
            expectFits("tab row \(start / OnboardingMetrics.tabsPerRow)", total, visual, row.joined(separator: ", "))
        }
        #expect(problems.isEmpty, Comment(rawValue: "\(language):\n" + problems.joined(separator: "\n")))
    }

    /// The English of a tab's name, which is also its key.
    private static func englishTitle(_ tab: NotchTab) -> String {
        switch tab {
        case .home: "Home"
        case .shelf: "Shelf"
        case .timer: "Timer"
        case .clipboard: "Clipboard"
        case .notes: "Notes"
        case .tools: "Tools"
        case .system: "System"
        case .apps: "Apps"
        case .search: "Search"
        case .emoji: "Emoji"
        case .ai: "AI usage"
        case .notices: "Notifications"
        case .agents: "Agents"
        case .mirror: "Mirror"
        }
    }

    @Test func theKeysTheFitTestMeasuresAreSentencesTheTourSays() throws {
        let said = Set(try Translations.keys())
        for key in ["This is Nunsseop", "Tabs are icons", "Drop and search", "Drop files", "Connect your agents", "You're all set",
                    "Hover over the notch, or swipe down with two fingers, to open it. Move the pointer away to close it.",
                    "Move the pointer to the top center to open it, away to close it.",
                    "The pill fades after %lld seconds and returns at the top edge.",
                    "Tabs show only icons; hover over one to see its name. Here they have labels.",
                    "Right-click the notch › Settings… to hide or reorder tabs.",
                    "Tools found on this Mac are listed. Connect one to see its sessions and reply in the Agents tab.",
                    "Or connect later in Settings › Alerts.", "Asks once to trust the hooks", "Not connected", "Retry", "Open at login",
                    "Couldn't change %@", "Permissions are asked only on first use", "Calendar, screen recording and camera: when used",
                    "On · change in Settings › General", "Off · change in Settings › General", "Drag files onto the notch", "to open Search",
                    "They collect on the Shelf. Send them with AirDrop or Share; screenshots land there too.",
                    "Find apps, files, commands and emoji, and do math."] {
            #expect(said.contains(key), Comment(rawValue: key))
        }
    }
}
