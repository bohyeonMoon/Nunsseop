import SwiftUI
import Testing
@testable import Nunsseop

@MainActor
struct ShowsSneakPeekTests {
    private func shows(enabled: Bool = true, call: String? = nil, track: Bool? = nil, lyrics: Bool = false,
                       always: Bool = false, pending: Bool = false) -> Bool {
        NotchViewModel.showsSneakPeek(enabled: enabled, callTitle: call, track: track, lyricsLive: lyrics,
                                      always: always, pending: pending)
    }

    @Test func nothingShowsWithoutATrackOrACall() {
        #expect(!shows())
        #expect(!shows(lyrics: true, always: true, pending: true))
    }

    @Test func switchedOffNeverShowsEvenForACall() {
        #expect(!shows(enabled: false, call: "Standup", track: true, lyrics: true, always: true, pending: true))
    }

    @Test func aCallsTitleShowsWithoutATrack() {
        #expect(shows(call: "Standup"))
    }

    @Test func aTrackShowsOnlyWhileItIsPendingOrAlways() {
        #expect(!shows(track: true))
        #expect(shows(track: true, pending: true))
        #expect(shows(track: false, pending: true))
        #expect(shows(track: false, always: true))
    }

    @Test func lyricsKeepThePeekUpOnlyWhilePlaying() {
        #expect(shows(track: true, lyrics: true))
        #expect(!shows(track: false, lyrics: true))
    }

    @Test func lyricsNeedToBeKnownForTheSong() {
        #expect(!shows(track: true, lyrics: false))
    }
}

@MainActor
struct InlinePeekClampTests {
    @Test func aShortLineGetsTheMinimum() {
        #expect(NotchViewModel.clampedPeekWidth(100, screenWidth: 1440) == 240)
        #expect(NotchViewModel.clampedPeekWidth(240, screenWidth: 1440) == 240)
    }

    @Test func aLineInBetweenKeepsItsWidth() {
        #expect(NotchViewModel.clampedPeekWidth(333, screenWidth: 1440) == 333)
    }

    @Test func aLongLineStopsAtAThirdOfTheScreen() {
        #expect(NotchViewModel.clampedPeekWidth(900, screenWidth: 1440) == 480)
        #expect(NotchViewModel.clampedPeekWidth(900, screenWidth: 3000) == 900)
    }

    @Test func aSmallScreenCapsBelowTheMinimum() {
        // The third of the screen wins over the 240 minimum; the line then truncates.
        #expect(NotchViewModel.clampedPeekWidth(100, screenWidth: 600) == 200)
    }
}

@MainActor
struct AirDropTargetTests {
    @Test func theRightSideStartsWhereTheListEndsAndReachesTheShapesInset() {
        let rect = NotchView.airDropRect(in: CGSize(width: 620, height: 196), collapsedHeight: 32)
        // 620 wide with 32 either side leaves 556; the list takes 40 % of that.
        #expect(abs(rect.minX - (32 + 556 * 0.4)) < 0.001)
        #expect(abs(rect.width - 556 * 0.6) < 0.001)
        #expect(rect.minY == 40)
        #expect(rect.height == 140)
    }

    @Test func withoutANotchTheHeaderIsShorterSoTheRightSideStartsHigher() {
        let rect = NotchView.airDropRect(in: CGSize(width: 620, height: 196), collapsedHeight: 18)
        #expect(rect.minY == 32)
        #expect(rect.height == 148)
    }

    @Test func theRightSideStartsBelowTheHeaderBarForEveryHeight() {
        // HeaderBar is max(collapsed height, 24) tall, with 8 below it.
        for height in [16, 18, 24, 31, 32, 38] as [CGFloat] {
            #expect(NotchView.airDropRect(in: CGSize(width: 620, height: 196), collapsedHeight: height).minY == max(height, 24) + 8)
        }
    }

    @Test func theRightSideKeepsTheShapesInsetFromItsRightEdgeAndTheListsShareOfTheWidth() {
        for width in [540, 620, 780] as [CGFloat] {
            let rect = NotchView.airDropRect(in: CGSize(width: width, height: 196), collapsedHeight: 32)
            #expect(rect.maxX == width - 32)
            #expect(abs(rect.minX - (32 + (width - 64) * ShelfView.listFraction)) < 0.001)
        }
    }

    @Test func aDropIsAirDroppedOnlyOverTheRightSideOfTheOpenShelf() {
        let rect = CGRect(x: 512, y: 40, width: 76, height: 140)
        let inside = CGPoint(x: 550, y: 100)
        #expect(NotchDropDelegate.targetsAirDrop(at: inside, in: rect, expanded: true, tab: .shelf))
        #expect(!NotchDropDelegate.targetsAirDrop(at: inside, in: rect, expanded: false, tab: .shelf))
        #expect(!NotchDropDelegate.targetsAirDrop(at: inside, in: rect, expanded: true, tab: .home))
    }

    @Test func aDropJustOutsideTheRightSideGoesToTheShelf() {
        let rect = CGRect(x: 512, y: 40, width: 76, height: 140)
        #expect(!NotchDropDelegate.targetsAirDrop(at: CGPoint(x: 511, y: 100), in: rect, expanded: true, tab: .shelf))
        #expect(!NotchDropDelegate.targetsAirDrop(at: CGPoint(x: 550, y: 39), in: rect, expanded: true, tab: .shelf))
        #expect(NotchDropDelegate.targetsAirDrop(at: CGPoint(x: 512, y: 40), in: rect, expanded: true, tab: .shelf))
    }
}
