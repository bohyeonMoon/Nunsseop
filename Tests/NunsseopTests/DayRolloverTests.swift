import AppKit
import Foundation
import Testing
@testable import Nunsseop

/// A clock the tests move by hand, standing in for midnight.
private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// The notifications that make the models check the day again.
enum DayEvent: CaseIterable {
    case dayChanged, clockChanged, wake

    func post() {
        switch self {
        case .dayChanged: NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        case .clockChanged: NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        case .wake: NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
    }
}

/// The observers run on the main queue, so the check happens a moment after the post.
@MainActor private func settle(until done: () -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(eventDeadline)
    while !done() && Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
}

private func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

/// One at a time: the day notifications are posted process-wide, so models of parallel tests would answer each other's.
@Suite(.serialized)
enum DayRolloverTests {
    @MainActor
    struct CalendarDayRolloverTests {
        @Test func selectionFollowsTodayPastMidnight() {
            let clock = Clock(time(10, 23, 59))
            let model = CalendarModel(calendar: utc, now: { clock.date })
            #expect(model.selectedDay == time(10, 0))
            clock.date = time(11, 0, 1)
            model.refreshToday()
            #expect(model.today == time(11, 0))
            #expect(model.selectedDay == time(11, 0))
            #expect(model.week.first == time(11, 0))
        }

        @Test func aPickedDayStaysPicked() {
            let clock = Clock(time(10, 23, 59))
            let model = CalendarModel(calendar: utc, now: { clock.date })
            model.selectedDay = time(12, 0)
            clock.date = time(11, 0, 1)
            model.refreshToday()
            #expect(model.today == time(11, 0))
            #expect(model.selectedDay == time(12, 0))
            #expect(model.week.first == time(11, 0))
        }

        @Test func aPickedDayThatFellOutOfTheWeekMovesToToday() {
            let clock = Clock(time(10, 22))
            let model = CalendarModel(calendar: utc, now: { clock.date })
            model.selectedDay = time(11, 0)
            clock.date = time(12, 8)
            model.refreshToday()
            #expect(model.today == time(12, 0))
            #expect(model.selectedDay == time(12, 0))
            #expect(model.week.contains(model.selectedDay))
        }

        @Test func nothingChangesWithinTheDay() {
            let clock = Clock(time(10, 8))
            let model = CalendarModel(calendar: utc, now: { clock.date })
            clock.date = time(10, 23)
            model.refreshToday()
            #expect(model.today == time(10, 0))
            #expect(model.selectedDay == time(10, 0))
        }

        @Test(arguments: DayEvent.allCases) func eachDayEventRefreshesToday(_ event: DayEvent) async throws {
            let clock = Clock(time(10, 23, 59))
            let model = CalendarModel(calendar: utc, now: { clock.date })
            clock.date = time(11, 0, 1)
            event.post()
            try await settle { model.today == time(11, 0) }
            #expect(model.today == time(11, 0))
            #expect(model.selectedDay == time(11, 0))
        }
    }

    @MainActor
    struct PomodoroDayRolloverTests {
        private static let suiteName = "NunsseopTests.DayRollover"

        /// A Pomodoro timer on the 10th at 22:00 with its first work session running; the work lasts 25 minutes.
        private func runningTimer(_ clock: Clock) -> TimerModel {
            let defaults = UserDefaults(suiteName: Self.suiteName)!
            defaults.removePersistentDomain(forName: Self.suiteName)
            let timer = TimerModel(defaults: defaults, calendar: utc, now: { clock.date }, chime: {})
            timer.mode = .pomodoro
            timer.start()
            return timer
        }

        /// Finishes two work sessions and their rests; a third work session is then running until 25 minutes
        /// after the second rest was handled, which is 23:45 unless that is late.
        private func finishTwoSessionsAndStartAThird(_ timer: TimerModel, _ clock: Clock, secondRestHandledAt: Date = time(10, 23, 20)) {
            clock.date = time(10, 22, 25)
            timer.tick()
            clock.date = time(10, 22, 30)
            timer.tick()
            clock.date = time(10, 22, 55)
            timer.tick()
            clock.date = secondRestHandledAt
            timer.tick()
        }

        @Test func aWorkSessionFinishingAfterMidnightIsTheNewDaysFirst() {
            let clock = Clock(time(10, 22))
            let timer = runningTimer(clock)
            defer { timer.reset() }
            finishTwoSessionsAndStartAThird(timer, clock, secondRestHandledAt: time(10, 23, 50))  // third session due 00:15
            #expect(timer.completedPomodoros == 2)
            clock.date = time(11, 0, 20)
            timer.tick()
            #expect(timer.phase == .rest)
            #expect(timer.completedPomodoros == 1)
        }

        @Test func aWorkSessionDueBeforeMidnightButHandledAfterBelongsToThePreviousDay() {
            let clock = Clock(time(10, 22))
            let timer = runningTimer(clock)
            defer { timer.reset() }
            finishTwoSessionsAndStartAThird(timer, clock)  // third session due 23:45
            clock.date = time(11, 0, 30)  // the Mac slept through it
            timer.rollDay()
            timer.tick()
            #expect(timer.phase == .rest)
            #expect(timer.completedPomodoros == 0)
        }

        @Test func aWorkSessionDueBeforeMidnightAndHandledBeforeItCountsToday() {
            let clock = Clock(time(10, 22))
            let timer = runningTimer(clock)
            defer { timer.reset() }
            finishTwoSessionsAndStartAThird(timer, clock)  // third session due 23:45
            clock.date = time(10, 23, 46)
            timer.tick()
            #expect(timer.completedPomodoros == 3)
        }

        @Test func aWorkSessionFinishingTheSameDayKeepsCounting() {
            let clock = Clock(time(10, 8))
            let timer = runningTimer(clock)
            defer { timer.reset() }
            clock.date = time(10, 8, 25)
            timer.tick()
            clock.date = time(10, 8, 30)
            timer.tick()
            clock.date = time(10, 8, 55)
            timer.tick()
            #expect(timer.completedPomodoros == 2)
        }

        @Test(arguments: DayEvent.allCases) func eachDayEventStartsTheCountOver(_ event: DayEvent) async throws {
            let clock = Clock(time(10, 22))
            let timer = runningTimer(clock)
            defer { timer.reset() }
            finishTwoSessionsAndStartAThird(timer, clock)
            #expect(timer.completedPomodoros == 2)
            timer.pause()  // the real ticker would count the now-due session first if the main actor stalled
            clock.date = time(11, 0, 1)
            event.post()
            try await settle { timer.completedPomodoros == 0 }
            #expect(timer.completedPomodoros == 0)
        }
    }
}
