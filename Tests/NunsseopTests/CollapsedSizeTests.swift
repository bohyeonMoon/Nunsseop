import AppKit
import Testing
@testable import Nunsseop

@MainActor
struct CollapsedSizeTests {
    private let brow = CGSize(width: 44, height: 18)
    private let notch = CGSize(width: 200, height: 32)

    private func size(base: CGSize? = nil, hasNotch: Bool = false, screen: CGFloat = 1440, event: HUDEvent? = nil,
                      live: Bool = false, ear: CGFloat = 38, idle: CGFloat? = nil, peek: Bool = false,
                      inline: CGFloat = 240) -> CGSize {
        NotchViewModel.collapsedSize(base: base ?? (hasNotch ? notch : brow), hasNotch: hasNotch, screenWidth: screen,
                                     event: event, showsLiveActivity: live, earWidth: ear, idleGrowth: idle,
                                     showsSneakPeek: peek, inlinePeekWidth: inline)
    }

    /// The text as the notice line draws it, measured the long way round.
    private func lineWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: HUDContent.lineFont]).size().width)
    }

    private let notice = HUDEvent.notice(symbol: "bolt.fill", title: "Fully charged", detail: nil)

    // MARK: Without a notch

    @Test func aLevelHUDWithoutANotchIsOneRowWithRoomForTheBar() {
        // 18 each side, the 20 symbol slot, the 7 gap and a 110 bar.
        #expect(size(event: .volume(0.5, muted: false)) == CGSize(width: 173, height: 18))
        #expect(size(event: .brightness(0.2)) == CGSize(width: 173, height: 18))
        #expect(size(event: .keyboard(0)) == CGSize(width: 173, height: 18))
    }

    @Test func aPowerHUDWithoutANotchIsOneRowWithRoomForThePercent() {
        #expect(size(event: .power(PowerState(percent: 80, isCharging: false, onAC: false))) == CGSize(width: 99, height: 18))
    }

    @Test func aOneRowHUDNeverShrinksBelowTheEyebrow() {
        #expect(size(base: CGSize(width: 200, height: 18), event: .volume(0.5, muted: false)).width == 200)
    }

    @Test func aShortNoticeWithoutANotchFitsItsText() {
        let width = size(event: notice).width
        #expect(width == 36 + 27 + lineWidth("Fully charged"))
        #expect(width > 44)
        #expect(size(event: notice).height == 18)
    }

    @Test func aNoticeWithADetailMeasuresBothWithTheSeparator() {
        let event = HUDEvent.notice(symbol: "calendar", title: "Standup", detail: "in 5 minutes")
        #expect(size(event: event).width == 36 + 27 + lineWidth("Standup  ·  in 5 minutes"))
    }

    @Test func aHeadphoneNoticeWithoutANotchShowsOneLine() {
        let battery = HeadphoneBattery(name: "AirPods", levels: [("Left", 90), ("Case", 60)])
        let result = size(event: .headphones(battery))
        #expect(result.width == 36 + 27 + lineWidth("AirPods  ·  Left 90%  ·  Case 60%"))
        #expect(result.height == 18)
    }

    @Test func aLongNoticeStopsAtAThirdOfTheScreen() {
        let long = HUDEvent.notice(symbol: "bolt.fill", title: String(repeating: "W", count: 400), detail: nil)
        #expect(size(screen: 1440, event: long) == CGSize(width: 480, height: 18))
        #expect(size(screen: 2400, event: long).width == 800)
    }

    @Test func aNoticeOnATinyScreenKeepsAtLeastTheEyebrow() {
        let long = HUDEvent.notice(symbol: "bolt.fill", title: String(repeating: "W", count: 400), detail: nil)
        #expect(size(screen: 90, event: long).width == 44)
    }

    // MARK: With a notch

    @Test func aNoticeAroundANotchGrowsAnEarOnEachSideAndAnotherRowDown() {
        #expect(size(hasNotch: true, event: notice) == CGSize(width: 404, height: 56))
        #expect(size(hasNotch: true, event: .headphones(HeadphoneBattery(name: "AirPods", levels: [("Left", 90)]))) == CGSize(width: 404, height: 56))
    }

    @Test func aLevelHUDAroundANotchGrowsEarsButNotDownward() {
        #expect(size(hasNotch: true, event: .volume(0.5, muted: false)) == CGSize(width: 404, height: 32))
        #expect(size(hasNotch: true, event: .brightness(1)) == CGSize(width: 404, height: 32))
        #expect(size(hasNotch: true, event: .power(PowerState(percent: 5, isCharging: false, onAC: false))) == CGSize(width: 404, height: 32))
    }

    @Test func aHUDOutranksALiveActivityAndAPeek() {
        #expect(size(hasNotch: true, event: .volume(0.5, muted: false), live: true, idle: 50, peek: true).width == 404)
    }

    // MARK: Live activity, idle ears, peek

    @Test func aLiveActivityGrowsAnEarOnEachSide() {
        #expect(size(hasNotch: true, live: true) == CGSize(width: 276, height: 32))
        #expect(size(live: true, ear: 50) == CGSize(width: 144, height: 18))
    }

    @Test func idleValuesAddTheirGrowth() {
        #expect(size(idle: 60) == CGSize(width: 104, height: 18))
        #expect(size(idle: nil) == brow)
    }

    @Test func aLiveActivityOutranksIdleValues() {
        #expect(size(live: true, idle: 140).width == 120)
    }

    @Test func theSneakPeekAroundANotchIsAtLeast300WideAndOneRowTaller() {
        #expect(size(hasNotch: true, peek: true) == CGSize(width: 300, height: 56))
    }

    @Test func aWideShapeKeepsItsWidthUnderTheSneakPeek() {
        #expect(size(hasNotch: true, idle: 140, peek: true) == CGSize(width: 340, height: 56))
        #expect(size(hasNotch: true, live: true, ear: 74, peek: true) == CGSize(width: 348, height: 56))
    }

    @Test func theInlinePeekWithoutANotchIsOneRowAsWideAsItsLine() {
        // The line and 13 of padding on each side; no extra row.
        #expect(size(peek: true, inline: 240) == CGSize(width: 266, height: 18))
        #expect(size(peek: true, inline: 400).width == 426)
    }

    @Test func theInlinePeekMakesRoomForTheEarsOfALiveActivity() {
        #expect(size(live: true, ear: 38, peek: true, inline: 240).width == 342)
    }

    @Test func theInlinePeekIgnoresIdleValues() {
        #expect(size(idle: 140, peek: true, inline: 240).width == 266)
    }

    @Test func theInlinePeekNeverShrinksTheShape() {
        #expect(size(base: CGSize(width: 500, height: 18), peek: true, inline: 240).width == 500)
    }

    @Test func theInlineLineIsOnlyMeasuredWhenItIsUsed() {
        var measured = false
        _ = NotchViewModel.collapsedSize(base: notch, hasNotch: true, screenWidth: 1440, event: nil, showsLiveActivity: false,
                                         earWidth: 38, idleGrowth: nil, showsSneakPeek: true,
                                         inlinePeekWidth: { measured = true; return 999 }())
        #expect(!measured)
    }
}

@MainActor
struct CollapsedHitAreaTests {
    private func geometry(hasNotch: Bool) -> NotchGeometry {
        var g = NotchGeometry()
        g.hasNotch = hasNotch
        g.collapsedSize = hasNotch ? CGSize(width: 200, height: 32) : CGSize(width: 44, height: 18)
        return g
    }

    @Test func theBareEyebrowReachesEightPointsPastEachSideAndUpToTheScreenEdge() {
        let g = geometry(hasNotch: false)
        let rect = NotchViewModel.collapsedRect(geometry: g, size: g.collapsedSize, shift: 0)
        // 44 wide, centred on 720, plus 8 each side; the 3 point gap above it counts.
        #expect(rect == NSRect(x: 690, y: 879, width: 60, height: 21))
        #expect(rect.maxY == g.screenFrame.maxY)
    }

    @Test func aWiderShapeWithoutANotchHasNoSlack() {
        let g = geometry(hasNotch: false)
        let rect = NotchViewModel.collapsedRect(geometry: g, size: CGSize(width: 173, height: 18), shift: 0)
        #expect(rect == NSRect(x: 633.5, y: 879, width: 173, height: 21))
    }

    @Test func aNotchedShapeIsExactlyTheDrawnShape() {
        let g = geometry(hasNotch: true)
        let rect = NotchViewModel.collapsedRect(geometry: g, size: g.collapsedSize, shift: 0)
        #expect(rect == NSRect(x: 620, y: 868, width: 200, height: 32))
    }

    @Test func theHitAreaFollowsTheShapeWhenItShifts() {
        let g = geometry(hasNotch: false)
        let size = CGSize(width: 144, height: 18)
        let drawn = g.shapeRect(size: size).offsetBy(dx: 50, dy: 0)
        let rect = NotchViewModel.collapsedRect(geometry: g, size: size, shift: 50)
        #expect(rect.minX == drawn.minX)
        #expect(rect.maxX == drawn.maxX)
        let left = NotchViewModel.collapsedRect(geometry: g, size: size, shift: -15)
        #expect(left.minX == drawn.minX - 65)
    }

    @Test func theSlackAroundTheBareEyebrowMovesWithTheShape() {
        let g = geometry(hasNotch: false)
        let rect = NotchViewModel.collapsedRect(geometry: g, size: g.collapsedSize, shift: 10)
        #expect(rect.minX == 700)
        #expect(rect.width == 60)
    }
}

struct MenuOverlapTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private func menu(_ minX: CGFloat, _ maxX: CGFloat, y: CGFloat = 878) -> CGRect {
        CGRect(x: minX, y: y, width: maxX - minX, height: 22)
    }

    /// The camera spans 698...742; at width 244 each ear is 100.
    private func reaches(_ menus: [CGRect], width: CGFloat = 244, ear: CGFloat = 100, screen: NSRect? = nil) -> Bool {
        NotchViewModel.menusReachLeftEar(menus: menus, screen: screen ?? self.screen, notch: 44, width: width, ear: ear)
    }

    @Test func menusUnderTheLeftEarHideIt() {
        #expect(reaches([menu(560, 640)]))
    }

    @Test func menusThatAlsoReachTheRightRegionLeaveTheLeftEarAlone() {
        #expect(!reaches([menu(560, 640), menu(742, 842)]))
        #expect(!reaches([menu(560, 780)]))
    }

    @Test func menusFurtherLeftThanTheEarDoNotMatter() {
        #expect(!reaches([menu(300, 500)]))
        // Touching the ear's edge is not covering it.
        #expect(!reaches([menu(500, 598)]))
        #expect(reaches([menu(500, 599)]))
    }

    @Test func menusRightOfTheRightRegionDoNotMatter() {
        // The right region spans 742...942.
        #expect(reaches([menu(560, 640), menu(950, 1000)]))
        #expect(!reaches([menu(560, 640), menu(900, 1000)]))
    }

    @Test func aMenuWhoseCentreIsOffScreenIsIgnored() {
        #expect(!reaches([menu(560, 640, y: 950)]))
        #expect(!reaches([menu(-300, -220)]))
        // But its neighbours on the screen still count.
        #expect(reaches([menu(560, 640, y: 950), menu(600, 650)]))
    }

    @Test func noMenusMeansNothingToHide() {
        #expect(!reaches([]))
    }

    @Test func aShapeNoWiderThanTheCameraHasNoEarToHide() {
        #expect(!reaches([menu(560, 700)], width: 44, ear: 0))
        #expect(!reaches([menu(560, 700)], width: 30, ear: 0))
    }

    @Test func aFittedEarSmallerThanHalfTheGrowthOnlyCountsItsOwnRoom() {
        // A 30 wide ear reaches 668...698, so a menu ending at 660 is clear of it.
        #expect(!reaches([menu(560, 660)], width: 144, ear: 30))
        #expect(reaches([menu(560, 670)], width: 144, ear: 30))
    }

    @Test func aDisplayWithItsOwnOriginIsMeasuredFromItsCentre() {
        let second = NSRect(x: 1440, y: 0, width: 1440, height: 900)
        // The camera now spans 2138...2182.
        #expect(reaches([menu(2000, 2100)], screen: second))
        #expect(!reaches([menu(560, 640)], screen: second))
    }
}

struct CollapsedShiftTests {
    @Test func bothFittedSidesMoveTheShapeByHalfTheirDifference() {
        // 134 wide: left 30, right 60.
        #expect(NotchViewModel.collapsedShift(fitted: (30, 60), hidesLeftEar: false, width: 134, notch: 44) == 15)
        #expect(NotchViewModel.collapsedShift(fitted: (60, 30), hidesLeftEar: false, width: 134, notch: 44) == -15)
        #expect(NotchViewModel.collapsedShift(fitted: (40, 40), hidesLeftEar: false, width: 124, notch: 44) == 0)
    }

    @Test func aHiddenLeftEarMakesTwoFittedSidesGrowRightOnly() {
        // The shape starts at the camera's left edge: it moves right by half its growth.
        #expect(NotchViewModel.collapsedShift(fitted: (30, 60), hidesLeftEar: true, width: 134, notch: 44) == 45)
    }

    @Test func aHiddenLeftEarDoesNotMoveASingleFittedSide() {
        #expect(NotchViewModel.collapsedShift(fitted: (0, 60), hidesLeftEar: true, width: 104, notch: 44) == 30)
        #expect(NotchViewModel.collapsedShift(fitted: (60, 0), hidesLeftEar: true, width: 104, notch: 44) == -30)
    }

    @Test func aShiftedShapeKeepsItsLeftEdgeAtTheCameraWhenTheLeftEarIsHidden() {
        let width: CGFloat = 244, notch: CGFloat = 44
        let shift = NotchViewModel.collapsedShift(fitted: nil, hidesLeftEar: true, width: width, notch: notch)
        #expect(-width / 2 + shift == -notch / 2)
    }
}
