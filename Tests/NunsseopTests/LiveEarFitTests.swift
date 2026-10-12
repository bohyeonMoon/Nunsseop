import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

private typealias Content = CollapsedActivity.Content

/// What the collapsed live activity can show, one value per case the notch handles.
@MainActor
private enum Case {
    static let call = NSImage(systemSymbolName: "video.circle.fill", accessibilityDescription: nil)!

    /// A clock counting up from the reference date.
    static let up = CollapsedActivity.Clock(seconds: { $0.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0)) })

    static let pomodoro = Content(left: .timer, right: .timer, clock: .init(seconds: { _ in 29 * 60 + 50 }, fixedLength: 30 * 60))
    static let pomodoroRest = Content(left: .timer, right: .timer, timerTint: .green,
                                      clock: .init(seconds: { _ in 4 * 60 + 50 }, fixedLength: 5 * 60))
    static let stopwatch = Content(left: .timer, right: .timer, timerSymbol: "stopwatch.fill", clock: up)
    static let download = Content(left: .download, right: .download, percent: 55)
    static let downloadUnknown = Content(left: .download, right: .download)
    static let calling = Content(left: .call, right: .call, callIcon: call, clock: up)
    static let callingMuted = Content(left: .call, right: .call, callIcon: call, muted: true, clock: up)
    static let recording = Content(left: .recording, right: .recording, clock: up)
    /// A recording that began at `start`.
    static func recordingFrom(_ start: Date) -> Content {
        Content(left: .recording, right: .recording, clock: .init(seconds: { $0.timeIntervalSince(start) }))
    }
    static let music = Content(left: .music, right: .bars, playing: true)
    static let musicPrivacyDots = Content(left: .music, right: .privacyDots, playing: true, camera: true, mic: true)
    static let musicAndTimer = Content(left: .music, right: .timer, playing: true,
                                       clock: .init(seconds: { _ in 29 * 60 + 50 }, fixedLength: 30 * 60))
    static let privacyCamera = Content(left: .privacy, right: .bars, camera: true)
    static let privacyBoth = Content(left: .privacy, right: .bars, camera: true, mic: true)

    /// Every case whose sides are fitted to what they hold.
    static let fitted: [(String, Content)] = [
        ("pomodoro", pomodoro), ("pomodoro-rest", pomodoroRest), ("stopwatch", stopwatch), ("download", download),
        ("download-unknown", downloadUnknown), ("call", calling), ("call-muted", callingMuted), ("recording", recording),
        ("music-timer", musicAndTimer), ("privacy-camera", privacyCamera), ("privacy-both", privacyBoth),
    ]
    /// The artwork and visualizer cases, which keep the ear they always had.
    static let legacy: [(String, Content)] = [("music", music), ("music-privacy-dots", musicPrivacyDots)]
}

@MainActor
struct LiveEarWidthTests {
    private let now = Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(1000)
    private func sides(_ content: Content, art: CGFloat = 18, base: CGFloat = 38) -> LiveEars.Sides {
        LiveEars.sides(for: content, art: art, base: base, at: now)
    }

    // MARK: Left content

    @Test func theLeftSideIsAsWideAsItsContent() {
        #expect(LiveEars.leftWidth(Case.recording, art: 18) == 8)
        #expect(LiveEars.leftWidth(Case.calling, art: 18) == 18)
        #expect(LiveEars.leftWidth(Case.music, art: 18) == 18)
        #expect(LiveEars.leftWidth(Case.calling, art: 10) == 10)
        for content in [Case.pomodoro, Case.stopwatch, Case.download] {
            let width = LiveEars.leftWidth(content, art: 18)
            #expect(width > 8 && width < 20, "\(width)")
        }
    }

    @Test func privacySymbolsAddUpWithAGapBetweenThem() {
        let one = LiveEars.leftWidth(Case.privacyCamera, art: 18)
        let both = LiveEars.leftWidth(Case.privacyBoth, art: 18)
        #expect(one > 8)
        #expect(both > one + 3)
        #expect(both < 2 * one + 3 + 4)
    }

    // MARK: Right content

    @Test func theRightSideIsAsWideAsItsContent() {
        // Two dots of 6 with 3 between, or one; the bars are two points narrower than the artwork.
        #expect(LiveEars.rightWidth(Case.musicPrivacyDots, art: 18, at: now) == 15)
        #expect(LiveEars.rightWidth(Case.music, art: 18, at: now) == 16)
        let clock = LiveEars.rightWidth(Case.pomodoro, art: 18, at: now)
        #expect(clock > 25 && clock < 45, "\(clock)")
        // A muted call adds the mic-slash and its 3 gap.
        let call = LiveEars.rightWidth(Case.calling, art: 18, at: now)
        let muted = LiveEars.rightWidth(Case.callingMuted, art: 18, at: now)
        #expect(muted > call + 8 && muted < call + 16)
    }

    @Test func aDownloadsPercentTakesItsDigitsAndTheEllipsisItsSymbol() {
        func width(_ percent: Int?) -> CGFloat {
            LiveEars.rightWidth(Content(left: .download, right: .download, percent: percent), art: 18, at: now)
        }
        // Monospaced digits: every one-digit value is as wide as any other, and every two-digit one.
        #expect(width(1) == width(9))
        #expect(width(10) == width(99))
        #expect(width(100) > width(99))
        #expect(width(99) > width(9))
        #expect(width(nil) > 5)
    }

    // MARK: Clocks

    @Test func anElapsedClockIsSizedForMinutesAndSecondsFromTheStart() {
        #expect(LiveEars.clockText(elapsed: 0) == "10:00")
        #expect(LiveEars.clockText(elapsed: 599) == "10:00")
        #expect(LiveEars.clockText(elapsed: 600) == "10:00")
        #expect(LiveEars.clockText(elapsed: 3599) == "10:00")
        #expect(LiveEars.clockText(elapsed: 3600) == "1:00:00")
        #expect(LiveEars.clockText(elapsed: 36000 - 1) == "1:00:00")
        #expect(LiveEars.clockText(elapsed: 36000) == "10:00:00")
    }

    @Test func aStopwatchCallOrRecordingDoesNotChangeWidthWithinAnHour() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let widths = Set((0..<3600).map { LiveEars.rightWidth(Case.stopwatch, art: 18, at: start.addingTimeInterval(TimeInterval($0))) })
        #expect(widths.count == 1)
        for content in [Case.calling, Case.recording] {
            let widths = Set((stride(from: 0, to: 3600, by: 7)).map {
                LiveEars.rightWidth(content, art: 18, at: start.addingTimeInterval(TimeInterval($0)))
            })
            #expect(widths.count == 1)
        }
    }

    @Test func theClockGrowsAtTheHourAndAtTenHours() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func width(_ seconds: TimeInterval) -> CGFloat { LiveEars.rightWidth(Case.stopwatch, art: 18, at: start.addingTimeInterval(seconds)) }
        #expect(width(3599) < width(3600))
        #expect(width(3600) == width(36000 - 1))
        #expect(width(36000 - 1) < width(36000))
    }

    @Test func aCountdownKeepsOneWidthWhateverItReads() {
        func width(_ seconds: TimeInterval, of length: TimeInterval) -> CGFloat {
            let content = Content(left: .timer, right: .timer, clock: .init(seconds: { _ in seconds }, fixedLength: length))
            return LiveEars.rightWidth(content, art: 18, at: now)
        }
        // 10:00 → 9:59 and 1:00:00 → 59:59 do not change the shape; the length it started with decides.
        #expect(width(600, of: 1500) == width(599, of: 1500))
        #expect(width(1500, of: 1500) == width(5, of: 1500))
        #expect(width(3600, of: 3600) == width(3599, of: 3600))
        // A five-minute rest has one minute digit; 25 minutes of work has two; an hour has hours too.
        #expect(width(300, of: 300) < width(1500, of: 1500))
        #expect(width(1500, of: 1500) < width(3600, of: 3600))
    }

    @Test func theNextWidthChangeIsTheHourOrTenHoursOfTheClockThatReachesItFirst() {
        let a = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(LiveEars.nextClockChange(after: a, startingAt: []) == nil)
        #expect(LiveEars.nextClockChange(after: a, startingAt: [a.addingTimeInterval(-10)]) == a.addingTimeInterval(3590))
        #expect(LiveEars.nextClockChange(after: a, startingAt: [a.addingTimeInterval(-3600)]) == a.addingTimeInterval(36000 - 3600))
        #expect(LiveEars.nextClockChange(after: a, startingAt: [a.addingTimeInterval(-36000)]) == nil)
        // The nearest of several, and one just reached is already past.
        #expect(LiveEars.nextClockChange(after: a, startingAt: [a.addingTimeInterval(-10), a.addingTimeInterval(-3000)])
                == a.addingTimeInterval(600))
        #expect(LiveEars.nextClockChange(after: a, startingAt: [a.addingTimeInterval(-3600)]) != a)
    }

    // MARK: Sides

    @Test func eachFittedSideIsTheWallMarginTheContentAndTheGapToTheCamera() {
        for (name, content) in Case.fitted {
            let result = sides(content)
            let left = LiveEars.leftWidth(content, art: 18), right = LiveEars.rightWidth(content, art: 18, at: now)
            #expect(result.left == LiveEars.margin + left + LiveEars.gap, "\(name)")
            #expect(result.right == LiveEars.margin + right + LiveEars.gap, "\(name)")
            // So the empty space beside the camera is the same on both sides.
            #expect(result.left - LiveEars.margin - left == result.right - LiveEars.margin - right, "\(name)")
        }
    }

    @Test func aTimerLeftEarNoLongerHoldsRoomForTheClock() {
        let result = sides(Case.pomodoro)
        #expect(result.left < 36)
        #expect(result.right > result.left)
        // Roughly what the one ear for both sides took in total.
        #expect(result.left + result.right < 2 * 50)
    }

    @Test func artworkAndVisualizerKeepTheirEqualEarsOnEveryHeight() {
        for (height, art) in [(32, 18), (38, 24), (24, 10), (18, 4), (60, 32)] as [(CGFloat, CGFloat)] {
            let base = NotchViewModel.earWidth(height: height, compact: false)
            for (name, content) in Case.legacy {
                #expect(sides(content, art: art, base: base) == LiveEars.Sides(left: base, right: base), "\(name) \(height)")
            }
            let compact = NotchViewModel.earWidth(height: height, compact: true)
            #expect(sides(Case.music, art: art, base: compact) == LiveEars.Sides(left: compact, right: compact))
        }
    }

    @Test func musicWithATextOnTheRightIsFittedLikeTheOthers() {
        let result = sides(Case.musicAndTimer)
        #expect(result.left == LiveEars.margin + 18 + LiveEars.gap)
        #expect(result != LiveEars.Sides(left: 38, right: 38))
    }

    @Test func aPeekBelowTheNotchKeepsTheTwoEarsEqualSoItStaysCentred() {
        let fitted = sides(Case.pomodoro)
        let peek = LiveEars.sides(for: Case.pomodoro, art: 18, base: 38, at: now, symmetric: true)
        #expect(peek.left == peek.right)
        #expect(peek.left == max(fitted.left, fitted.right))
    }

    // MARK: The shape around them

    @Test func theShapeMovesSoTheCameraStaysCentred() {
        let result = sides(Case.pomodoro)
        let notch: CGFloat = 200
        let width = notch + result.left + result.right
        let shift = NotchViewModel.collapsedShift(fitted: (result.left, result.right), hidesLeftEar: false, width: width, notch: notch)
        #expect(shift == (result.right - result.left) / 2)
        // The camera's left edge, from the shape's left wall, lands at the screen's centre less half the camera.
        let wall = -width / 2 + shift
        #expect(abs(wall + result.left - -notch / 2) < 0.001)
        #expect(NotchViewModel.browLead(width: width, notch: notch, shift: shift) == result.left)
    }

    @Test func withTheLeftEarHiddenTheShapeStartsAtTheCamera() {
        let result = sides(Case.pomodoro)
        let notch: CGFloat = 200
        let width = notch + result.left + result.right
        let shift = NotchViewModel.collapsedShift(fitted: (result.left, result.right), hidesLeftEar: true, width: width, notch: notch)
        #expect(shift == (width - notch) / 2)
        #expect(NotchViewModel.browLead(width: width, notch: notch, shift: shift) == 0)
    }

    @Test func theShapeIsTheCameraAndTheTwoSides() {
        let result = LiveEars.Sides(left: 31, right: 52)
        let size = NotchViewModel.collapsedSize(base: CGSize(width: 200, height: 32), hasNotch: true, screenWidth: 1440, event: nil,
                                                showsLiveActivity: true, liveSides: result, idleGrowth: nil,
                                                showsSneakPeek: false, inlinePeekWidth: 240)
        #expect(size == CGSize(width: 283, height: 32))
    }

    @Test func anInlinePeekMakesRoomForTheWiderSideOnBoth() {
        let result = LiveEars.Sides(left: 40, right: 40)
        let size = NotchViewModel.collapsedSize(base: CGSize(width: 44, height: 18), hasNotch: false, screenWidth: 1440, event: nil,
                                                showsLiveActivity: true, liveSides: result, idleGrowth: nil,
                                                showsSneakPeek: true, inlinePeekWidth: 240)
        // Two ears of 40, the line and 13 of padding on each side.
        #expect(size.width == 346)
    }
}

@MainActor
struct LiveEarUpkeepTests {
    private let now = Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(1000)

    // MARK: Tiny panels

    @Test func theArtworkNeverHasANegativeSide() {
        #expect(LiveEars.art(height: 32) == 18)
        #expect(LiveEars.art(height: 14) == 0)
        #expect(LiveEars.art(height: 3) == 0)
        #expect(LiveEars.art(height: -20) == 0)
        #expect(LiveEars.rightWidth(Case.privacyCamera, art: 0, at: now) == 0)
        #expect(LiveEars.rightWidth(Case.privacyCamera, art: 1, at: now) == 0)
        #expect(LiveEars.leftWidth(Case.music, art: LiveEars.art(height: 5)) == 0)
    }

    // MARK: Sleep and clock changes

    @Test func aChangeThatFellDueWhileAsleepIsWaitedForNoLonger() {
        let due = now.addingTimeInterval(600)
        #expect(LiveEars.clockChangeDelay(until: due, now: now) == 600)
        #expect(LiveEars.clockChangeDelay(until: due, now: due) == 0)
        // Woken an hour later: the mark has passed, so the notch is measured at once.
        #expect(LiveEars.clockChangeDelay(until: due, now: now.addingTimeInterval(3600)) == 0)
    }

    @Test func wakingAndSettingTheClockAreWhatMeasuresTheNotchAgain() {
        let names = LiveEars.clockJumpNotifications.map(\.name)
        #expect(names.contains(NSWorkspace.didWakeNotification))
        #expect(names.contains(.NSSystemClockDidChange))
        // Waking is posted on the workspace's own center, not the default one.
        let wake = LiveEars.clockJumpNotifications.first { $0.name == NSWorkspace.didWakeNotification }
        #expect(wake?.center === NSWorkspace.shared.notificationCenter)
    }

    @Test func aMarkPassedAsleepIsSeenByMeasuringAgain() {
        // The hour mark of a clock begun an hour and a minute before waking is past, and the width is the longer format's.
        let start = now.addingTimeInterval(-3660)
        #expect(LiveEars.nextClockChange(after: now, startingAt: [start]) == start.addingTimeInterval(36000))
        let asleep = LiveEars.rightWidth(Case.recordingFrom(start), art: 18, at: now.addingTimeInterval(-120))
        let awake = LiveEars.rightWidth(Case.recordingFrom(start), art: 18, at: now)
        #expect(awake > asleep)
    }

    // MARK: Measuring once

    @Test func widthsAreTheSameWhenMeasuredAgainAndAreKept() {
        let symbol = LiveEars.symbolWidth("mic.fill", size: 10)
        let text = LiveEars.textWidth("1:23:45")
        let kept = LiveEars.cachedWidthCount
        for _ in 0..<200 {
            #expect(LiveEars.symbolWidth("mic.fill", size: 10) == symbol)
            #expect(LiveEars.textWidth("1:23:45") == text)
        }
        #expect(LiveEars.cachedWidthCount == kept)
        // Another size of the same symbol is a different width, not the kept one.
        #expect(LiveEars.symbolWidth("mic.fill", size: 20) > symbol)
        // And what is kept is what measuring gives.
        let measured = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))?.size.width
        #expect(symbol == measured)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        #expect(text == ceil(("1:23:45" as NSString).size(withAttributes: [.font: font]).width))
    }

    @Test func aSymbolThatDoesNotExistIsWidthlessAndStaysSo() {
        #expect(LiveEars.symbolWidth("not.a.symbol.at.all", size: 10) == 0)
        #expect(LiveEars.symbolWidth("not.a.symbol.at.all", size: 10) == 0)
    }

    // MARK: Which way the ears move

    private func frame(_ width: CGFloat, _ height: CGFloat = 32, _ left: CGFloat, _ right: CGFloat, peek: Bool = false)
        -> NotchViewModel.EarsFrame {
        NotchViewModel.EarsFrame(size: CGSize(width: width, height: height), sides: .init(left: left, right: right), peek: peek)
    }

    @Test func aPeekEndingIsAShrinkEvenThoughTheSidesChangeToo() {
        // The line goes and the sides stop being equal in one transaction.
        let peeking = frame(200 + 104, 56, 52, 52, peek: true)
        let after = frame(200 + 83, 32, 31, 52)
        #expect(!NotchViewModel.earsGrow(from: peeking, to: after))
        // A line that only lowers the shape ending is one too.
        #expect(!NotchViewModel.earsGrow(from: frame(283, 56, 31, 52, peek: true), to: frame(283, 32, 31, 52)))
    }

    @Test func aPeekStartingOrAClockGainingADigitGrows() {
        #expect(NotchViewModel.earsGrow(from: frame(283, 32, 31, 52), to: frame(304, 56, 52, 52, peek: true)))
        #expect(NotchViewModel.earsGrow(from: frame(283, 32, 31, 52), to: frame(283, 56, 31, 52, peek: true)))
        #expect(NotchViewModel.earsGrow(from: frame(283, 32, 31, 52), to: frame(297, 32, 31, 66)))
    }

    @Test func anActivityEndingShrinksAndOneStartingGrows() {
        #expect(!NotchViewModel.earsGrow(from: frame(283, 32, 31, 52), to: frame(200, 32, 0, 0)))
        #expect(NotchViewModel.earsGrow(from: frame(200, 32, 0, 0), to: frame(283, 32, 31, 52)))
    }

    @Test func whenTheSizeStaysPutThePeekThenTheSidesDecide() {
        #expect(NotchViewModel.earsGrow(from: frame(283, 32, 31, 52), to: frame(283, 32, 52, 31)))
        #expect(!NotchViewModel.earsGrow(from: frame(200, 32, 0, 0), to: frame(200, 32, 0, 0)))
        #expect(NotchViewModel.earsGrow(from: frame(200, 32, 0, 0), to: frame(200, 32, 0, 0, peek: true)))
        #expect(!NotchViewModel.earsGrow(from: frame(200, 32, 0, 0, peek: true), to: frame(200, 32, 0, 0)))
    }

    @Test func theAnimationKeyIgnoresTheSize() {
        let a = frame(283, 32, 31, 52), b = frame(300, 56, 31, 52)
        #expect(a != b)
        #expect(a.key == b.key)
        #expect(a.key != frame(283, 32, 31, 52, peek: true).key)
    }
}

@MainActor
struct LiveEarRenderTests {
    private let now = Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(1000)
    /// A notched display's camera area and bar height, and a plain one's brow and bar height.
    private let displays: [(name: String, hasNotch: Bool, camera: CGFloat, height: CGFloat)] = [
        ("notch", true, 200, 32), ("flat", false, 44, 24),
    ]

    private func render(_ name: String, _ content: Content, display: (name: String, hasNotch: Bool, camera: CGFloat, height: CGFloat))
        -> (EarRender.Measure, LiveEars.Sides) {
        let art = LiveEars.art(height: display.height)
        let base = NotchViewModel.earWidth(height: display.height, compact: false)
        let sides = LiveEars.sides(for: content, art: art, base: base, at: now)
        let row = LiveRow(content: content, height: display.height, at: now)
        let width = display.camera + sides.left + sides.right
        let rep = EarRender.pixels(EarRender.marked(row, left: sides.left, right: sides.right, camera: display.camera, height: display.height),
                                   width: width, height: display.height)
        let measure = EarRender.measure(rep, left: sides.left, camera: display.camera)
        if let directory = ProcessInfo.processInfo.environment["EAR_FIT_RENDER_DIR"] {
            EarRender.savePNG(rep, to: "\(directory)/measure-after-\(name)-\(display.name).png")
            let pretty = EarRender.pixels(EarRender.pill(row, left: sides.left, right: sides.right, camera: display.camera,
                                                         height: display.height, hasNotch: display.hasNotch),
                                          width: width + 28, height: display.height + 28)
            EarRender.savePNG(pretty, to: "\(directory)/after-\(name)-\(display.name).png")
            let line = "AFTER \(display.name) \(name) left=\(sides.left) right=\(sides.right) leftGap=\(measure.leftGap) "
                + "rightGap=\(measure.rightGap) leftMargin=\(measure.leftMargin) rightMargin=\(measure.rightMargin)\n"
            let url = URL(fileURLWithPath: "\(directory)/after-gaps.txt")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        return (measure, sides)
    }

    @Test func theEmptySpaceBesideTheCameraIsTheSameOnBothSides() {
        for display in displays {
            for (name, content) in Case.fitted {
                let (m, _) = render(name, content, display: display)
                #expect(!m.intrudes, "\(name) \(display.name): content over the camera")
                #expect(abs(m.leftGap - m.rightGap) <= 2, "\(name) \(display.name): left \(m.leftGap), right \(m.rightGap)")
                // And it is the gap the layout reserves, give or take the symbols' own padding.
                #expect(abs(m.leftGap - LiveEars.gap) <= 2.5 && abs(m.rightGap - LiveEars.gap) <= 2.5,
                        "\(name) \(display.name): left \(m.leftGap), right \(m.rightGap)")
            }
        }
    }

    @Test func theOuterMarginIsTheSameOnBothSides() {
        for display in displays {
            for (name, content) in Case.fitted {
                let (m, _) = render(name, content, display: display)
                #expect(abs(m.leftMargin - EarRender.wallMargin) <= 1.5, "\(name) \(display.name): \(m.leftMargin)")
                #expect(abs(m.rightMargin - EarRender.wallMargin) <= 1.5, "\(name) \(display.name): \(m.rightMargin)")
            }
        }
    }

    @Test func artworkAndVisualizerLookAsTheyDid() {
        for display in displays {
            for (name, content) in Case.legacy {
                let (m, sides) = render(name, content, display: display)
                let base = NotchViewModel.earWidth(height: display.height, compact: false)
                #expect(sides == LiveEars.Sides(left: base, right: base))
                #expect(!m.intrudes)
                if name == "music" {
                    // The artwork 7 from the camera and the bars 9, as before.
                    #expect(abs(m.leftGap - 7) <= 0.5, "\(display.name): \(m.leftGap)")
                    #expect(abs(m.rightGap - 9) <= 0.5, "\(display.name): \(m.rightGap)")
                }
            }
        }
    }

    @Test func aLongerClockStillFitsItsSide() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for seconds in [5.0, 754, 3601, 36001] {
            let content = Content(left: .recording, right: .recording, clock: .init(seconds: { $0.timeIntervalSince(start) }))
            let at = start.addingTimeInterval(seconds)
            let sides = LiveEars.sides(for: content, art: 18, base: 38, at: at)
            let row = LiveRow(content: content, height: 32, at: at)
            let rep = EarRender.pixels(EarRender.marked(row, left: sides.left, right: sides.right, camera: 200, height: 32),
                                       width: 200 + sides.left + sides.right, height: 32)
            let m = EarRender.measure(rep, left: sides.left, camera: 200)
            #expect(!m.intrudes, "\(seconds)")
            #expect(m.rightGap >= LiveEars.gap - 2.5, "\(seconds): \(m.rightGap)")
            #expect(m.rightMargin >= EarRender.wallMargin - 1.5, "\(seconds): \(m.rightMargin)")
        }
    }
}

/// The live activity's content as the models settle it, which is what the notch sizes its sides from.
@MainActor
@Suite(.serialized)
struct LiveContentTests {
    private static let suiteName = "NunsseopTests.LiveContent"

    private func content(timer: TimerModel, call: CallMonitor.Call? = nil, muted: Bool = false) -> Content {
        CollapsedActivity.content(nowPlaying: NowPlayingController(), timer: timer, recorder: ScreenRecorder(),
                                  downloads: DownloadWatcher(), privacy: nil, call: call, callMuted: muted,
                                  showsMusic: true, showsTimer: true, showsDownloads: true)
    }

    private func withTimer(_ body: (TimerModel) -> Void) {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        let timer = TimerModel(defaults: defaults)
        defer {
            timer.reset()
            defaults.removePersistentDomain(forName: Self.suiteName)
        }
        body(timer)
    }

    @Test func aRunningPomodoroShowsItsClockAndIsSizedForItsLength() {
        withTimer { timer in
            timer.mode = .pomodoro
            timer.workMinutes = 30
            timer.start()
            let live = content(timer: timer)
            #expect(live.left == .timer && live.right == .timer)
            #expect(live.timerSymbol == "timer")
            #expect(live.clock?.fixedLength == TimeInterval(30 * 60))
            // However far down it has counted, the shape stays the size it started at.
            let start = Date.now
            let widths = Set(stride(from: 0, to: 1800, by: 13).map {
                LiveEars.rightWidth(live, art: 18, at: start.addingTimeInterval(TimeInterval($0)))
            })
            #expect(widths.count == 1)
        }
    }

    @Test func aPomodoroBreakIsGreenAndSizedForTheBreak() {
        withTimer { timer in
            timer.mode = .pomodoro
            timer.selectPhase(.rest)
            timer.start()
            let live = content(timer: timer)
            #expect(live.timerTint == .green)
            #expect(live.clock?.fixedLength == TimeInterval(5 * 60))
        }
    }

    @Test func aStopwatchCountsUpAndHasNoFixedLength() {
        withTimer { timer in
            timer.mode = .stopwatch
            timer.start()
            let live = content(timer: timer)
            #expect(live.timerSymbol == "stopwatch.fill")
            #expect(live.timerTint == .orange)
            #expect(live.clock?.fixedLength == nil)
        }
    }

    @Test func aCallShowsItsAppAndWhetherItIsMuted() {
        withTimer { timer in
            let call = CallMonitor.Call(appName: "Zoom", bundleID: "us.zoom.xos", icon: Case.call,
                                        startedAt: .now.addingTimeInterval(-60), title: nil)
            let live = content(timer: timer, call: call, muted: true)
            #expect(live.left == .call && live.right == .call)
            #expect(live.callIcon === Case.call)
            #expect(live.muted)
            #expect((live.clock?.seconds(.now) ?? 0) >= 59)
        }
    }
}
