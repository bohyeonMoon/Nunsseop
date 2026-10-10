import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct ExpandedWidthTests {
    @Test func twelveTabsAroundANotchNeedTwoWideSidesAndTheCamera() {
        // Each side 320, the camera's 200 + 8, the 12 between the halves, and 32 of inset on each end.
        #expect(NotchViewModel.fittingWidth(tabCount: 12, status: 180, hasNotch: true, notchWidth: 200) == 924)
    }

    @Test func twelveTabsWithoutANotchNeedOneRowAndTheStatusIcons() {
        // 12 × 36 - 6, the 12 gap, the 180 of status and 64 of inset.
        #expect(NotchViewModel.fittingWidth(tabCount: 12, status: 180, hasNotch: false, notchWidth: 44) == 682)
    }

    @Test func homeAloneIsNarrow() {
        #expect(NotchViewModel.fittingWidth(tabCount: 1, status: 64, hasNotch: false, notchWidth: 44) == 170)
    }

    @Test func theNotchedWidthDoesNotDependOnTheCameraBeyondItsOwnWidth() {
        let narrow = NotchViewModel.fittingWidth(tabCount: 8, status: 130, hasNotch: true, notchWidth: 200)
        let wide = NotchViewModel.fittingWidth(tabCount: 8, status: 130, hasNotch: true, notchWidth: 384)
        #expect(wide - narrow == 184)
    }

    @Test func theSavedWidthWinsWhenItAlreadyFits() {
        #expect(NotchViewModel.widened(780, fitting: 682, limit: 1200) == 780)
    }

    @Test func theFittingWidthWinsWhenTheSavedOneIsTooNarrow() {
        #expect(NotchViewModel.widened(620, fitting: 924, limit: 1200) == 924)
    }

    @Test func theFittingWidthStopsAtThePanelLimit() {
        #expect(NotchViewModel.widened(620, fitting: 924, limit: 920) == 920)
        // A limit below the saved width never narrows it.
        #expect(NotchViewModel.widened(620, fitting: 924, limit: 500) == 620)
    }

    @Test func theHeaderReservesRoomForEachStatusIcon() {
        // Settings and Quit are 26 wide with a 6 gap each; the battery adds 66 and the weather 50.
        #expect(NotchViewModel.headerStatusWidth(battery: false, weather: false) == 64)
        #expect(NotchViewModel.headerStatusWidth(battery: true, weather: false) == 130)
        #expect(NotchViewModel.headerStatusWidth(battery: false, weather: true) == 114)
        #expect(NotchViewModel.headerStatusWidth(battery: true, weather: true) == 180)
    }

    private let statuses: [CGFloat] = [64, 130, 114, 180]

    @Test func aNotchedHeaderAtTheFittingWidthSplitsAroundTheCamera() {
        for notch in [44, 200, 384] as [CGFloat] {
            for count in 1...13 {
                for status in statuses {
                    let width = NotchViewModel.fittingWidth(tabCount: count, status: status, hasNotch: true, notchWidth: notch)
                    let layout = HeaderBar.layout(width: width, status: status, tabCount: count, hasNotch: true, notchWidth: notch)
                    let split = NotchViewModel.tabSplit(count: count, status: status)
                    #expect(layout.left == split.left, "count \(count), status \(status), notch \(notch)")
                    #expect(layout.camera == notch + 8)
                    #expect(abs(layout.side - split.side) < 0.001)
                }
            }
        }
    }

    @Test func aNotchedHeaderTwoPointsTooNarrowFallsBackToOneScrollingRow() {
        let width = NotchViewModel.fittingWidth(tabCount: 12, status: 180, hasNotch: true, notchWidth: 200)
        // Half a point of slack is allowed on each side, so one point narrower still splits.
        #expect(HeaderBar.layout(width: width - 1, status: 180, tabCount: 12, hasNotch: true, notchWidth: 200).left != nil)
        #expect(HeaderBar.layout(width: width - 2, status: 180, tabCount: 12, hasNotch: true, notchWidth: 200).left == nil)
    }

    @Test func aHeaderWithoutANotchHasRoomForEveryTabAtTheFittingWidth() {
        for count in 1...13 {
            for status in statuses {
                let width = NotchViewModel.fittingWidth(tabCount: count, status: status, hasNotch: false, notchWidth: 44)
                let layout = HeaderBar.layout(width: width, status: status, tabCount: count, hasNotch: false, notchWidth: 44)
                #expect(layout.strip == NotchViewModel.stripWidth(count), "count \(count), status \(status)")
                #expect(layout.left == nil)
                #expect(layout.camera == 0)
            }
        }
    }

    @Test func theFittingWidthStaysInsideThePanelForEveryTabCountOnTheCommonDisplays() {
        // A 14" MacBook Pro's notch, with every tab and every status icon.
        var g = NotchGeometry()
        g.screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        g.hasNotch = true
        g.collapsedSize = CGSize(width: 384, height: 32)
        let count = NotchTab.allCases.count
        let width = NotchViewModel.widened(620, fitting: NotchViewModel.fittingWidth(tabCount: count, status: 180, hasNotch: true, notchWidth: 384),
                                           limit: g.maxExpandedWidth)
        #expect(width <= g.maxExpandedWidth)
        #expect(width <= g.panelFrame.width - 40)
    }
}

@MainActor
struct TabAfterCollapseTests {
    private let all: (NotchTab) -> Bool = { _ in true }

    @Test func mirrorIsLeftSoTheCameraCannotStartOnReopen() {
        #expect(NotchViewModel.tabAfterCollapse(.mirror, isVisible: all) == .home)
    }

    @Test func aVisibleTabIsKept() {
        for tab in NotchTab.allCases where tab != .mirror {
            #expect(NotchViewModel.tabAfterCollapse(tab, isVisible: all) == tab)
        }
    }

    @Test func aTabTheSettingsHideIsLeft() {
        let withoutSearch: (NotchTab) -> Bool = { $0 != .search }
        #expect(NotchViewModel.tabAfterCollapse(.search, isVisible: withoutSearch) == .home)
        #expect(NotchViewModel.tabAfterCollapse(.timer, isVisible: withoutSearch) == .timer)
    }

    @Test func mirrorSwitchedOffStillGoesHome() {
        #expect(NotchViewModel.tabAfterCollapse(.mirror, isVisible: { $0 != .mirror }) == .home)
    }

    @Test func homeStaysHome() {
        #expect(NotchViewModel.tabAfterCollapse(.home, isVisible: all) == .home)
    }

    @Test func aHiddenTabIsLeftWithoutClosingToo() {
        #expect(NotchViewModel.visibleTab(.mirror, isVisible: { $0 != .mirror }) == .home)
        // Closing is what resets a visible Mirror, not a settings change.
        #expect(NotchViewModel.visibleTab(.mirror, isVisible: all) == .mirror)
    }
}
