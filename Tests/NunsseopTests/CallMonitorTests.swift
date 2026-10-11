import Foundation
import Testing
@testable import Nunsseop

struct CallTrackerTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func startsOnFirstActiveKey() {
        var tracker = CallMonitor.Tracker()
        tracker.update(active: ["zoom", "teams"], at: t0)
        #expect(tracker.key == "zoom")
        #expect(tracker.startedAt == t0)
    }

    @Test func survivesShortGapsAndEndsAfterGrace() {
        var tracker = CallMonitor.Tracker()
        tracker.update(active: ["zoom"], at: t0)
        tracker.update(active: [], at: t0 + 3)
        #expect(tracker.key == "zoom")
        tracker.update(active: ["zoom"], at: t0 + 4)
        tracker.update(active: [], at: t0 + 8)
        #expect(tracker.key == "zoom")
        tracker.update(active: [], at: t0 + 9)
        #expect(tracker.key == nil)
        #expect(tracker.startedAt == nil)
    }

    @Test func confirmedCallStaysWhileAppPlaysAudio() {
        var tracker = CallMonitor.Tracker()
        tracker.update(active: ["zoom"], at: t0)
        tracker.update(active: ["zoom"], at: t0 + 10)
        tracker.update(active: [], alive: ["zoom"], at: t0 + 30)
        #expect(tracker.key == "zoom")
        tracker.update(active: [], at: t0 + 36)
        #expect(tracker.key == nil)
    }

    @Test func unconfirmedCallDoesNotStayOnPlaybackAlone() {
        var tracker = CallMonitor.Tracker()
        tracker.update(active: ["zoom"], at: t0)
        tracker.update(active: [], alive: ["zoom"], at: t0 + 6)
        #expect(tracker.key == nil)
    }

    @Test func switchesOnlyAfterGrace() {
        var tracker = CallMonitor.Tracker()
        tracker.update(active: ["zoom"], at: t0)
        tracker.update(active: ["teams"], at: t0 + 1)
        #expect(tracker.key == "zoom")
        tracker.update(active: ["teams"], at: t0 + 7)
        #expect(tracker.key == "teams")
        #expect(tracker.startedAt == t0 + 7)
    }
}

struct CallServiceTests {
    private func tab(_ url: String, _ title: String = "", active: Bool = false) -> BrowserMedia.Tab {
        BrowserMedia.Tab(url: url, title: title, isActive: active)
    }

    @Test func recognisesMeetingLinksInAnyTab() {
        #expect(CallMonitor.service(for: tab("https://meet.google.com/abc-defg-hij")) == "Google Meet")
        #expect(CallMonitor.service(for: tab("https://us02web.zoom.us/wc/123456/join")) == "Zoom")
        #expect(CallMonitor.service(for: tab("https://app.slack.com/huddle/T1/C1")) == "Slack")
    }

    @Test func allDayAppsCountOnlyWhenActive() {
        #expect(CallMonitor.service(for: tab("https://teams.microsoft.com/v2/")) == nil)
        #expect(CallMonitor.service(for: tab("https://teams.microsoft.com/v2/", active: true)) == "Microsoft Teams")
        #expect(CallMonitor.service(for: tab("https://app.slack.com/client/T1", active: true)) == "Slack")
        #expect(CallMonitor.service(for: tab("https://discord.com/channels/1/2", active: true)) == "Discord")
        #expect(CallMonitor.service(for: tab("https://discord.com/app", active: true)) == nil)
    }

    @Test func ignoresNonMeetingPages() {
        #expect(CallMonitor.service(for: tab("https://meet.google.com/landing", active: true)) == nil)
        #expect(CallMonitor.service(for: tab("http://meet.google.com/abc-defg-hij")) == nil)
        #expect(CallMonitor.service(for: tab("https://zoom.us/pricing", active: true)) == nil)
        #expect(CallMonitor.service(for: tab("https://example.com", active: true)) == nil)
        #expect(CallMonitor.service(for: tab("not a url")) == nil)
    }

    @Test func bestCallPrefersMostSpecificService() throws {
        let best = try #require(CallMonitor.bestCall(in: [
            tab("https://app.slack.com/client/T1", "Slack", active: true),
            tab("https://meet.google.com/abc-defg-hij", "Meet - Weekly sync"),
        ]))
        #expect(best.service == "Google Meet")
        #expect(best.title == "Weekly sync")
        #expect(CallMonitor.bestCall(in: [tab("https://example.com", active: true)]) == nil)
        #expect(CallMonitor.bestCall(in: []) == nil)
    }

    @Test(arguments: [
        ("Meet - Weekly sync", "Weekly sync"), ("Weekly sync - Google Meet", "Weekly sync"),
        ("Design review – Meet", "Design review"), ("Meet – abc-defg-hij", nil), ("Google Meet", nil), ("Meet", nil),
    ] as [(String, String?)])
    func parsesMeetTitles(tabTitle: String, expected: String?) {
        #expect(CallMonitor.meetingTitle(tabTitle, service: "Google Meet") == expected)
    }

    @Test func otherServicesHaveNoTitle() {
        #expect(CallMonitor.meetingTitle("Weekly sync - Zoom", service: "Zoom") == nil)
    }

    @Test func mapsHelperProcessesToApps() {
        #expect(CallMonitor.appBundleID(for: "us.zoom.CptHost") == "us.zoom.xos")
        #expect(CallMonitor.appBundleID(for: "com.microsoft.VCXPC") == "com.microsoft.teams2")
        #expect(CallMonitor.appBundleID(for: "com.apple.Safari") == nil)
    }

    @Test func canaryIsNotStableChrome() {
        #expect(CallMonitor.browser(for: "com.google.Chrome.helper")?.bundleID == "com.google.Chrome")
        #expect(CallMonitor.browser(for: "com.google.Chrome")?.bundleID == "com.google.Chrome")
        #expect(CallMonitor.browser(for: "com.google.Chrome.canary")?.bundleID == "com.google.Chrome.canary")
        #expect(CallMonitor.browser(for: "com.google.Chrome.canary.helper")?.bundleID == "com.google.Chrome.canary")
    }

    @Test(arguments: [
        ("com.google.Chrome", "com.google.Chrome"), ("com.google.Chrome.beta", "com.google.Chrome.beta"),
        ("com.google.Chrome.dev", "com.google.Chrome.dev"),
        ("com.microsoft.edgemac", "com.microsoft.edgemac"), ("com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Beta"),
        ("com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Dev"), ("com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Canary"),
        ("com.brave.Browser", "com.brave.Browser"), ("com.brave.Browser.beta", "com.brave.Browser.beta"),
        ("com.brave.Browser.nightly", "com.brave.Browser.nightly"),
    ])
    func releaseChannelsAreNotTheStableBrowser(bundleID: String, expected: String) {
        #expect(CallMonitor.browser(for: bundleID)?.bundleID == expected)
        #expect(CallMonitor.browser(for: bundleID + ".helper")?.bundleID == expected)
    }
}
