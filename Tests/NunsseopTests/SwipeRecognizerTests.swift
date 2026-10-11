import AppKit
import Testing
@testable import Nunsseop

struct SwipeRecognizerTests {
    /// Natural scrolling on, so deltas already are the fingers' direction.
    private func swipe(_ steps: [(dx: CGFloat, dy: CGFloat)], inverted: Bool = true, opens: Bool = true,
                       tracks: Bool = true) -> [SwipeRecognizer.Action?] {
        var recognizer = SwipeRecognizer()
        return steps.map { recognizer.add(dx: $0.dx, dy: $0.dy, inverted: inverted, opens: opens, tracks: tracks) }
    }

    @Test func fingersMovingDownOpenTheNotchOnceAndStayQuiet() {
        #expect(swipe([(0, 30), (0, 15), (0, 100)]) == [nil, .open, nil])
    }

    @Test func fingersMovingUpCloseIt() {
        #expect(swipe([(0, -50)]) == [.close])
    }

    @Test func theSwipeNeedsMoreThanFortyPoints() {
        #expect(swipe([(0, 40)]) == [nil])
        #expect(swipe([(0, 41)]) == [.open])
    }

    @Test func aDiagonalSwipeDoesNothingUntilOneAxisClearlyWins() {
        // 50 against 40 is not 1.5 times as much.
        #expect(swipe([(40, 50)]) == [nil])
        #expect(swipe([(30, 50)]) == [.open])
    }

    @Test func leftSwipesSkipForwardAndRightSwipesGoBack() {
        #expect(swipe([(-45, 0)]) == [.nextTrack])
        #expect(swipe([(45, 5)]) == [.previousTrack])
    }

    @Test func smallMovesOnTheSameAxisAddUp() {
        #expect(swipe([(-30, 10), (-30, 10)]) == [nil, .nextTrack])
    }

    @Test func swipesAcrossTheTwoAxesFireOnlyOncePerGesture() {
        #expect(swipe([(0, 50), (-200, 0), (0, -300)]) == [.open, nil, nil])
    }

    @Test func resettingRearmsIt() {
        var recognizer = SwipeRecognizer()
        #expect(recognizer.add(dx: 0, dy: 50, inverted: true, opens: true, tracks: true) == .open)
        #expect(recognizer.add(dx: 0, dy: 50, inverted: true, opens: true, tracks: true) == nil)
        recognizer.reset()
        #expect(recognizer.add(dx: 0, dy: -50, inverted: true, opens: true, tracks: true) == .close)
    }

    @Test func resettingDropsTheDistanceAlreadyTravelled() {
        var recognizer = SwipeRecognizer()
        #expect(recognizer.add(dx: 0, dy: 30, inverted: true, opens: true, tracks: true) == nil)
        recognizer.reset()
        // 30 + 30 would be enough; after a reset it is only 30.
        #expect(recognizer.add(dx: 0, dy: 30, inverted: true, opens: true, tracks: true) == nil)
    }

    @Test func withoutNaturalScrollingTheDeltasAreFlippedBackToTheFingers() {
        #expect(swipe([(0, -50)], inverted: false) == [.open])
        #expect(swipe([(0, 50)], inverted: false) == [.close])
        #expect(swipe([(50, 0)], inverted: false) == [.nextTrack])
        #expect(swipe([(-50, 0)], inverted: false) == [.previousTrack])
    }

    @Test func openingNeedsItsSetting() {
        #expect(swipe([(0, 50)], opens: false) == [nil])
        // Another axis may still fire afterwards.
        #expect(swipe([(0, 50), (-200, 0)], opens: false) == [nil, .nextTrack])
    }

    @Test func skippingTracksNeedsAllItsConditions() {
        #expect(swipe([(-50, 0)], tracks: false) == [nil])
    }

    @Test func aVerticalSwipeNeverSkipsATrack() {
        #expect(swipe([(-20, 100)], opens: false) == [nil])
    }

    @Test func onlyTrackpadSwipesOverThePanelWithoutMomentumCount() {
        #expect(SwipeRecognizer.accepts(overPanel: true, precise: true, momentum: false))
        #expect(!SwipeRecognizer.accepts(overPanel: false, precise: true, momentum: false))
        #expect(!SwipeRecognizer.accepts(overPanel: true, precise: false, momentum: false))
        #expect(!SwipeRecognizer.accepts(overPanel: true, precise: true, momentum: true))
    }

    @Test func theExpandedHeaderBandIsTheCollapsedHeightPlusSix() {
        // A notch 32 high: the header is 32 + 6 deep.
        #expect(SwipeRecognizer.isOverHeader(fromTop: 37.9, collapsedHeight: 32))
        #expect(!SwipeRecognizer.isOverHeader(fromTop: 38, collapsedHeight: 32))
        // The eyebrow is shorter than the 24 point header floor.
        #expect(SwipeRecognizer.isOverHeader(fromTop: 29.9, collapsedHeight: 18))
        #expect(!SwipeRecognizer.isOverHeader(fromTop: 30, collapsedHeight: 18))
    }
}

struct HoverOpenDelayTests {
    @Test func aVisibleEyebrowOpensAfterTheSettingsDelay() {
        #expect(abs(NotchViewModel.hoverOpenDelay(base: 0.1, browRevealing: false) - 0.1) < 1e-9)
    }

    @Test func aFadedEyebrowAlsoWaitsOutItsDwell() {
        #expect(abs(NotchViewModel.hoverOpenDelay(base: 0.1, browRevealing: true) - (0.1 + 0.5 + 0.15)) < 1e-9)
    }
}

struct WheelSidewaysTests {
    private func wheel(vertical: Int32, horizontal: Int32 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: vertical, wheel2: horizontal, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func aWheelTurnedVerticallyScrollsHorizontallyInstead() throws {
        let moved = try #require(NotchWindowController.sideways(try wheel(vertical: 3)))
        #expect(moved.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(moved.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3)
        #expect(moved.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0)
        #expect(moved.cgEvent?.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0)
        #expect(moved.scrollingDeltaY == 0)
        #expect(moved.scrollingDeltaX != 0)
    }

    @Test func theDirectionIsKept() throws {
        let down = try #require(NotchWindowController.sideways(try wheel(vertical: -2)))
        let up = try #require(NotchWindowController.sideways(try wheel(vertical: 2)))
        #expect(down.scrollingDeltaX == -up.scrollingDeltaX)
        #expect(up.scrollingDeltaX != 0)
    }

    @Test func theOriginalEventIsNotChanged() throws {
        let original = try wheel(vertical: 3)
        _ = NotchWindowController.sideways(original)
        #expect(original.cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
    }
}
