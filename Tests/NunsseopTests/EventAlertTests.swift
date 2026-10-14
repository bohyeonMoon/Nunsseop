import EventKit
import Foundation
import SwiftUI
import Testing
@testable import Nunsseop

struct MeetingLinkTests {
    @Test func findsVideoCallLinks() {
        #expect(MeetingLink.find(in: ["https://us02web.zoom.us/j/123456?pwd=x"])?.host == "us02web.zoom.us")
        #expect(MeetingLink.find(in: [nil, "Room 4", "Join: https://meet.google.com/abc-defg-hij thanks"])?.absoluteString
                == "https://meet.google.com/abc-defg-hij")
        #expect(MeetingLink.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3a>"])?.host == "teams.microsoft.com")
        #expect(MeetingLink.find(in: ["https://acme.webex.com/meet/kim"]) != nil)
    }

    @Test func takesTheFirstFieldWithALink() {
        let url = MeetingLink.find(in: ["https://zoom.us/j/1", "https://meet.google.com/aaa-bbbb-ccc"])
        #expect(url?.host == "zoom.us")
    }

    @Test func meetingPathBeatsOtherLinksOnTheSameService() {
        let url = MeetingLink.find(in: ["Install https://zoom.us/download first", "https://us02web.zoom.us/j/987?pwd=y"])
        #expect(url?.absoluteString == "https://us02web.zoom.us/j/987?pwd=y")
        // Without a meeting link, a service link still counts.
        #expect(MeetingLink.find(in: ["https://zoom.us/download"])?.path == "/download")
    }

    @Test func unwrapsOutlookSafeLinks() {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=\(teams.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&data=05%7C01&reserved=0"
        #expect(MeetingLink.find(in: [wrapped])?.absoluteString == teams)
        #expect(MeetingLink.find(in: ["https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com"]) == nil)
    }

    @Test func upgradesHTTPToHTTPS() {
        #expect(MeetingLink.find(in: ["http://zoom.us/j/1"])?.absoluteString == "https://zoom.us/j/1")
    }

    @Test func rejectsSchemesOtherThanWeb() {
        #expect(MeetingLink.find(in: ["x-foo://zoom.us/j/1"]) == nil)
        #expect(MeetingLink.find(in: ["file://zoom.us/j/1"]) == nil)
        #expect(MeetingLink.find(in: ["zoommtg://zoom.us/join?confno=1"]) == nil)
        for inner in ["file://zoom.us/j/1", "x-foo://teams.microsoft.com/l/meetup-join/1", "javascript://zoom.us/j/1"] {
            let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=\(inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&reserved=0"
            #expect(MeetingLink.find(in: [wrapped]) == nil)
        }
        // A web meeting link after a rejected one is still found.
        #expect(MeetingLink.find(in: ["file://zoom.us/j/1 https://zoom.us/j/2"])?.absoluteString == "https://zoom.us/j/2")
    }

    @Test func ignoresOtherLinks() {
        #expect(MeetingLink.find(in: ["https://example.com/agenda", "https://notzoom.us/j/1", ""]) == nil)
        #expect(MeetingLink.find(in: []) == nil)
    }
}

struct EventAlertTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func event(_ id: String, in minutes: Double, allDay: Bool = false) -> CalendarItem {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarItem(id: id, title: id, start: start, end: start.addingTimeInterval(1800), isAllDay: allDay, color: .blue)
    }

    @Test func dueFiveMinutesBefore() {
        let items = [event("later", in: 30), event("soon", in: 4), event("sooner", in: 2)]
        let result = EventAlert.due(in: items, now: now, announced: [])
        #expect(result.due.map(\.id) == ["sooner", "soon"])
        #expect(result.next == now.addingTimeInterval(25 * 60))
    }

    @Test func skipsAnnouncedAllDayAndLongStarted() {
        let soon = event("soon", in: 3)
        let items = [soon, event("allDay", in: 1, allDay: true), event("started", in: -2), event("justStarted", in: -0.5)]
        let result = EventAlert.due(in: items, now: now, announced: [EventAlert.key(soon)])
        #expect(result.due.map(\.id) == ["justStarted"])
        #expect(result.next == nil)
    }

    @Test func repeatingOccurrencesHaveTheirOwnKey() {
        let today = event("standup", in: 3)
        let tomorrow = event("standup", in: 3 + 24 * 60)
        #expect(EventAlert.key(today) != EventAlert.key(tomorrow))
        let result = EventAlert.due(in: [today, tomorrow], now: now, announced: [EventAlert.key(today)])
        #expect(result.due.isEmpty)
        #expect(result.next == tomorrow.start.addingTimeInterval(-EventAlert.lead))
    }
}

struct EventAlertQueueTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func event(_ id: String, in minutes: Double) -> CalendarItem {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarItem(id: id, title: id, start: start, end: start.addingTimeInterval(1800), isAllDay: false, color: .blue)
    }

    @Test func eventsStartingTogetherKeepTheirSpacingWhenCheckedEarly() {
        var queue = EventAlertQueue(spacing: 8)
        let items = [event("a", in: 5), event("b", in: 5)]
        let first = queue.step(items: items, now: now)
        #expect(first.announce?.id == "a")
        #expect(first.next == now.addingTimeInterval(8))
        // An event store change three seconds later doesn't cut A's time short.
        let early = queue.step(items: items, now: now.addingTimeInterval(3))
        #expect(early.announce == nil)
        #expect(early.next == now.addingTimeInterval(8))
        let second = queue.step(items: items, now: now.addingTimeInterval(8))
        #expect(second.announce?.id == "b")
        #expect(queue.step(items: items, now: now.addingTimeInterval(20)).announce == nil)
    }

    @Test func announcesEachOccurrenceOnce() {
        var queue = EventAlertQueue(spacing: 8)
        let items = [event("a", in: 4), event("later", in: 60)]
        #expect(queue.step(items: items, now: now).announce?.id == "a")
        let again = queue.step(items: items, now: now.addingTimeInterval(30))
        #expect(again.announce == nil)
        #expect(again.next == items[1].start.addingTimeInterval(-EventAlert.lead))
    }
}

struct LastingNoticeTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func coveredNoticeComesBackForTheTimeItHadLeft() {
        var notices = LastingNotices<String>()
        notices.replace(with: "meeting", duration: 8, now: at(0))
        notices.replace(with: nil, duration: 1.6, now: at(3))      // volume HUD covers it
        notices.replace(with: nil, duration: 1.6, now: at(4))      // another volume step
        let back = notices.finish(now: at(5.6))
        #expect(back?.notice == "meeting")
        #expect(back?.remaining == 5)
        #expect(notices.finish(now: at(10.6)) == nil)              // shown out this time
    }

    @Test func noticeComesBackOnlyOnce() {
        // A and B start together; a volume HUD covers A, and B arrives on schedule while A is back.
        var notices = LastingNotices<String>()
        notices.replace(with: "A", duration: 8, now: at(0))
        notices.replace(with: nil, duration: 1.6, now: at(3))
        #expect(notices.finish(now: at(4.6))?.notice == "A")
        notices.replace(with: "B", duration: 8, now: at(8))
        #expect(notices.finish(now: at(16)) == nil)               // A isn't queued a third time
        #expect(notices.interrupted.isEmpty)
    }

    @Test func noticeNearlyDoneIsNotBroughtBack() {
        var notices = LastingNotices<String>()
        notices.replace(with: "meeting", duration: 8, now: at(0))
        notices.replace(with: nil, duration: 1.6, now: at(7.5))
        #expect(notices.finish(now: at(9.1)) == nil)
    }

    @Test func plainNoticesAreNotBroughtBack() {
        var notices = LastingNotices<String>()
        notices.replace(with: nil, duration: 1.6, now: at(0))
        notices.replace(with: nil, duration: 1.6, now: at(1))
        #expect(notices.finish(now: at(2.6)) == nil)
    }
}

struct StillDueTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func event(_ id: String, in minutes: Double) -> CalendarItem {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarItem(id: id, title: id, start: start, end: start.addingTimeInterval(1800), isAllDay: false, color: .blue)
    }

    @Test func showsWhileTheEventIsStillThere() {
        let item = event("a", in: 4)
        #expect(EventAlert.isStillDue(item, enabled: true, among: [item], now: now))
    }

    @Test func notOnceAlertsAreOff() {
        let item = event("a", in: 4)
        #expect(!EventAlert.isStillDue(item, enabled: false, among: [item], now: now))
    }

    @Test func notOnceCancelledDeletedOrMoved() {
        let item = event("a", in: 4)
        #expect(!EventAlert.isStillDue(item, enabled: true, among: [], now: now))
        #expect(!EventAlert.isStillDue(item, enabled: true, among: [event("a", in: 30)], now: now))
        #expect(!EventAlert.isStillDue(item, enabled: true, among: [event("b", in: 4)], now: now))
    }

    @Test func notOnceWellUnderWay() {
        let item = event("a", in: -2)
        #expect(!EventAlert.isStillDue(item, enabled: true, among: [item], now: now))
    }
}

struct AlertableEventTests {
    @Test func eventWithoutIdentifierIsSkipped() {
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Unsaved"
        event.startDate = .now
        event.endDate = .now.addingTimeInterval(600)
        #expect(event.eventIdentifier == nil || event.eventIdentifier == "")
        #expect(!CalendarModel.isAlertable(event))
    }
}

struct JoinButtonTests {
    @Test func joinOnlyUntilTheEventEnds() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let item = CalendarItem(id: "a", title: "a", start: start, end: start.addingTimeInterval(1800), isAllDay: false,
                                color: .blue, joinURL: URL(string: "https://zoom.us/j/1"))
        #expect(item.canJoin(at: start))
        #expect(!item.canJoin(at: start.addingTimeInterval(1800)))
        let noLink = CalendarItem(id: "b", title: "b", start: start, end: start.addingTimeInterval(1800), isAllDay: false, color: .blue)
        #expect(!noLink.canJoin(at: start))
    }
}


@MainActor
struct MeetingNoticeTests {
    func item(link: String?) -> CalendarItem {
        let start = Date.now.addingTimeInterval(300)
        return CalendarItem(id: "a", title: "Standup", start: start, end: start.addingTimeInterval(900), isAllDay: false,
                            color: .blue, joinURL: link.flatMap(URL.init(string:)))
    }

    @Test func noticeSaysAMeetingCanBeJoined() {
        let plain = NotchViewModel.upcomingDetail(item(link: nil))
        let joinable = NotchViewModel.upcomingDetail(item(link: "https://zoom.us/j/1"))
        #expect(!plain.contains("·"))
        #expect(joinable.hasPrefix(plain + " · "))
    }

    @Test func clickingAMeetingNoticeRunsItsActionEvenAfterBeingCovered() async {
        let hud = HUDCenter(settings: AppSettings.shared)
        var joined = 0
        // Long enough that a slow, busy runner (Intel under Rosetta) doesn't use it up before the cover goes.
        hud.showLasting(duration: 600, action: { joined += 1 }) { .notice(symbol: "video.fill", title: "Standup", detail: nil) }
        #expect(hud.action != nil)
        // A volume HUD covers it, then goes: the notice comes back, still clickable.
        hud.show(.volume(0.4, muted: false), duration: 0.05)
        #expect(hud.action == nil)
        await eventually { hud.action != nil }
        #expect(hud.action != nil)
        #expect(hud.performAction())
        #expect(joined == 1)
    }

    @Test func noticeWithoutALinkOpensTheNotchAsBefore() {
        let hud = HUDCenter(settings: AppSettings.shared)
        hud.showLasting(duration: 8) { .notice(symbol: "calendar", title: "Lunch", detail: nil) }
        #expect(hud.action == nil)
        #expect(!hud.performAction())
    }
}
