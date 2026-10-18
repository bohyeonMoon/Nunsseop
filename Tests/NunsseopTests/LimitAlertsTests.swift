import AppKit
import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct LimitAlertsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var resets: Date { now.addingTimeInterval(3600) }

    private func providers(claude session: Double?, weekly: Double? = nil, resetsAt: Date? = nil, codex: Double? = nil) -> [AIUsageModel.Provider] {
        let resetsAt = resetsAt ?? resets
        var list = [AIUsageModel.Provider(id: "claude", name: "Claude", session: session.map { .init(percent: $0, resetsAt: resetsAt) },
                                          weekly: weekly.map { .init(percent: $0, resetsAt: resetsAt) })]
        if let codex { list.append(AIUsageModel.Provider(id: "codex", name: "Codex", session: .init(percent: codex, resetsAt: resetsAt))) }
        return list
    }

    private func passing(_ alerts: [LimitAlerts.Alert]) -> [Int?] { alerts.map(\.threshold) }

    @Test func eachThresholdIsSaidOncePerWindow() {
        var tracker = LimitAlerts()
        #expect(tracker.step(providers(claude: 50), now: now).isEmpty)
        #expect(passing(tracker.step(providers(claude: 81), now: now)) == [80])
        #expect(tracker.step(providers(claude: 85), now: now).isEmpty)
        // A source that reads a little lower and then higher again doesn't count as passing it again.
        #expect(tracker.step(providers(claude: 78), now: now).isEmpty)
        #expect(tracker.step(providers(claude: 82), now: now).isEmpty)
        #expect(passing(tracker.step(providers(claude: 95), now: now)) == [95])
        #expect(tracker.step(providers(claude: 100), now: now).isEmpty)
    }

    @Test func aJumpPastBothSaysOnlyTheHigher() {
        var tracker = LimitAlerts()
        _ = tracker.step(providers(claude: 10), now: now)
        let alerts = tracker.step(providers(claude: 97), now: now)
        #expect(alerts == [LimitAlerts.Alert(family: .claude, kind: .session, threshold: 95, resetsAt: resets)])
        #expect(tracker.step(providers(claude: 99), now: now).isEmpty)
    }

    @Test func theFirstReadingOnlySetsWhatIsPassedAlready() {
        // After a relaunch at 85%, 80% isn't said again, but 95% still is.
        var tracker = LimitAlerts()
        #expect(tracker.step(providers(claude: 85), now: now).isEmpty)
        #expect(passing(tracker.step(providers(claude: 96), now: now)) == [95])
    }

    @Test func windowsAndToolsAreTrackedApart() {
        var tracker = LimitAlerts()
        _ = tracker.step(providers(claude: 10, weekly: 10, codex: 10), now: now)
        let alerts = tracker.step(providers(claude: 10, weekly: 90, codex: 96), now: now)
        #expect(alerts == [LimitAlerts.Alert(family: .claude, kind: .weekly, threshold: 80, resetsAt: resets),
                           LimitAlerts.Alert(family: .codex, kind: .session, threshold: 95, resetsAt: resets)])
    }

    @Test func aResetIsSaidWhenItsTimePassesEvenWithoutANewReading() {
        var tracker = LimitAlerts()
        _ = tracker.step(providers(claude: 50), now: now)
        _ = tracker.step(providers(claude: 90), now: now)
        // The status line drops a window once it has reset, so nothing comes in its place.
        let alerts = tracker.step(providers(claude: nil), now: resets)
        #expect(alerts == [LimitAlerts.Alert(family: .claude, kind: .session, threshold: nil, resetsAt: nil)])
        #expect(tracker.step(providers(claude: nil), now: resets.addingTimeInterval(60)).isEmpty)
        // The new window is announced from nothing: 80% is said again.
        let next = resets.addingTimeInterval(5 * 3600)
        #expect(tracker.step(providers(claude: 5, resetsAt: next), now: resets.addingTimeInterval(120)).isEmpty)
        #expect(passing(tracker.step(providers(claude: 80, resetsAt: next), now: resets.addingTimeInterval(180))) == [80])
    }

    @Test func aLargeFallIsAReset() {
        var tracker = LimitAlerts()
        _ = tracker.step(providers(claude: 50, resetsAt: .distantFuture), now: now)
        _ = tracker.step(providers(claude: 92, resetsAt: .distantFuture), now: now)
        #expect(passing(tracker.step(providers(claude: 3, resetsAt: .distantFuture), now: now)) == [nil])
        // A small one isn't.
        _ = tracker.step(providers(claude: 85, resetsAt: .distantFuture), now: now)
        #expect(tracker.step(providers(claude: 70, resetsAt: .distantFuture), now: now).isEmpty)
    }

    @Test func aResetIsOnlySaidForALimitThatGotFar() {
        var tracker = LimitAlerts()
        _ = tracker.step(providers(claude: 40), now: now)
        #expect(tracker.step(providers(claude: nil), now: resets).isEmpty)
    }

    @Test func wording() {
        let warning = LimitAlerts.Alert(family: .claude, kind: .session, threshold: 80, resetsAt: nil)
        #expect(LimitAlerts.title(warning) == "Claude 5-hour: \(LimitAlerts.share(80)) used")
        #expect(LimitAlerts.detail(warning) == nil)
        #expect(LimitAlerts.mood(warning) == .tired)
        let urgent = LimitAlerts.Alert(family: .codex, kind: .weekly, threshold: 95, resetsAt: now)
        #expect(LimitAlerts.title(urgent) == "Codex Weekly: \(LimitAlerts.share(95)) used")
        #expect(LimitAlerts.detail(urgent)?.hasPrefix("Resets ") == true)
        #expect(LimitAlerts.mood(urgent) == .tired)
        let reset = LimitAlerts.Alert(family: .claude, kind: .weekly, threshold: nil, resetsAt: nil)
        #expect(LimitAlerts.title(reset) == "Claude Weekly limit reset")
        #expect(LimitAlerts.detail(reset) == "Ready to use again")
        #expect(LimitAlerts.mood(reset) == .relieved)
        for alert in [warning, urgent, reset] {
            #expect(BrowMood(symbol: LimitAlerts.symbol(alert)) == LimitAlerts.mood(alert))
        }
    }

    @Test func theAlertSentencesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["Tell me when Claude or Codex limits are nearly used up, and when they reset",
                    "At %@ and %@ of the 5-hour or weekly limit, once each, and again when a limit that got that far resets.",
                    "%@ %@: %@ used", "%@ %@ limit reset", "Ready to use again"]
        let placeholders = [0, 2, 3, 2, 0]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for (key, count) in zip(keys, placeholders) {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                let found = (1...3).filter { text.contains("%\($0)$@") }.count
                #expect(found == count, Comment(rawValue: "\(language): \(key)"))
            }
        }
    }
}
