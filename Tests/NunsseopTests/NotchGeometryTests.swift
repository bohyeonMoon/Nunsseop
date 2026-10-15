import Foundation
import Testing
@testable import Nunsseop

struct DisplayCollapsedSizeTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

    private func size(frame: NSRect? = nil, menuBar: CGFloat = 0, safeTop: CGFloat = 0, left: CGFloat? = nil,
                      right: CGFloat? = nil, fake: CGFloat = 0) -> (size: CGSize, hasNotch: Bool) {
        let frame = frame ?? screen
        let visible = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - menuBar)
        return NotchGeometry.collapsedSize(frame: frame, visibleFrame: visible, safeTop: safeTop,
                                           leftAuxWidth: left, rightAuxWidth: right, fakeNotchWidth: fake)
    }

    @Test func aCameraHousingTakesTheWidthBetweenTheMenuBarHalvesAndTheSafeAreaHeight() {
        let notched = size(menuBar: 32, safeTop: 32, left: 570, right: 570)
        // 1512 - 570 - 570, plus 12 for the flared top corners.
        #expect(notched.size == CGSize(width: 384, height: 32))
        #expect(notched.hasNotch)
    }

    @Test func aSafeAreaWithoutBothMenuBarHalvesIsNotANotch() {
        #expect(size(menuBar: 37, safeTop: 32, left: nil, right: nil).hasNotch == false)
        #expect(size(menuBar: 37, safeTop: 32, left: 570, right: nil).hasNotch == false)
        #expect(size(menuBar: 37, safeTop: 32, left: nil, right: 570).hasNotch == false)
        // No safe area at all, even with both halves reported.
        #expect(size(menuBar: 24, safeTop: 0, left: 570, right: 570).hasNotch == false)
    }

    @Test func theEyebrowIsSixShorterThanTheMenuBar() {
        #expect(size(menuBar: 24).size == CGSize(width: NotchGeometry.browWidth, height: 18))
        #expect(size(menuBar: 37).size.height == 31)
        #expect(size(menuBar: 28).size.height == 22)
    }

    @Test func theEyebrowHasAFloorOfSixteen() {
        #expect(size(menuBar: 20).size.height == 16)
        #expect(size(menuBar: 22).size.height == 16)
        #expect(size(menuBar: 23).size.height == 17)
    }

    @Test func anAutoHiddenMenuBarFallsBackToA24PointBar() {
        // visibleFrame reaches the top, so the bar measures 0: it counts as 24, which gives 18 and not the floor of 16.
        #expect(size(menuBar: 0).size.height == 18)
        #expect(size(menuBar: 0).hasNotch == false)
    }

    @Test func theMenuBarIsMeasuredFromTheDisplaysOwnTopEdge() {
        // A second display placed above and right of the first.
        let second = NSRect(x: 1512, y: 982, width: 1920, height: 1080)
        #expect(size(frame: second, menuBar: 37).size.height == 31)
    }

    @Test func aFakeNotchOnlyAppliesWithoutARealOne() {
        let fake = size(menuBar: 24, fake: 200)
        #expect(fake.size == CGSize(width: 200, height: 32))
        #expect(fake.hasNotch)
        let real = size(menuBar: 32, safeTop: 32, left: 570, right: 570, fake: 200)
        #expect(real.size.width == 384)
    }
}

struct NotchGeometryTests {
    /// A display placed to the right of the main one, so nothing is at x = 0.
    private func geometry(width: CGFloat = 1512, hasNotch: Bool = true) -> NotchGeometry {
        var g = NotchGeometry()
        g.screenFrame = NSRect(x: 1440, y: 0, width: width, height: 982)
        g.hasNotch = hasNotch
        return g
    }

    @Test func theExpandedShapeMayGrowToTheScreenMinus80UpTo1200() {
        for (width, expected): (CGFloat, CGFloat) in [(1000, 920), (1280, 1200), (1512, 1200), (3840, 1200), (700, 780), (860, 780)] {
            #expect(geometry(width: width).maxExpandedWidth == expected)
        }
    }

    @Test func theWidestShapeNeverFallsBelowTheSettingsLimit() {
        #expect(geometry(width: 500).maxExpandedWidth == CGFloat(AppSettings.expandedWidthRange.upperBound))
    }

    @Test func thePanelIsCentredOnTheScreenAndFlushWithItsTop() {
        let g = geometry()
        let panel = g.panelFrame
        #expect(panel.size == CGSize(width: 1240, height: 280))
        #expect(panel.midX == 2196)
        #expect(panel.maxY == 982)
    }

    @Test func thePanelIsAlwaysWideEnoughForTheLargestShape() {
        for width in [700, 1000, 1280, 1512, 3840] as [CGFloat] {
            let g = geometry(width: width)
            #expect(g.panelFrame.width == g.maxExpandedWidth + 40)
            #expect(g.panelFrame.width >= CGFloat(AppSettings.expandedWidthRange.upperBound))
            #expect(g.panelFrame.height >= CGFloat(AppSettings.expandedHeightRange.upperBound))
        }
    }

    @Test func aNotchedShapeIsFlushWithTheTopEdge() {
        let g = geometry()
        #expect(g.topInset == 0)
        let rect = g.shapeRect(size: CGSize(width: 200, height: 32))
        #expect(rect.maxY == 982)
        #expect(rect.midX == 2196)
        #expect(rect.size == CGSize(width: 200, height: 32))
    }

    @Test func aFloatingEyebrowSitsThreePointsBelowTheTopEdge() {
        let g = geometry(hasNotch: false)
        #expect(g.topInset == 3)
        #expect(g.shapeRect(size: CGSize(width: 44, height: 18)).maxY == 979)
    }

    @Test func theExpandedShapeIgnoresTheInsetAndSitsAgainstTheTop() {
        let g = geometry(hasNotch: false)
        #expect(g.shapeRect(size: CGSize(width: 620, height: 196), inset: 0).maxY == 982)
    }

    @Test func theDefaultGeometryIsAnEyebrowOnA1440By900Screen() {
        let g = NotchGeometry()
        #expect(g.screenFrame == NSRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(g.collapsedSize == CGSize(width: 44, height: 18))
        #expect(!g.hasNotch)
    }
}

struct PickScreenTests {
    private let builtin = NotchGeometry.ScreenCandidate(name: "Built-in Retina Display", hasNotch: true, isMain: false, isBuiltin: true)
    private let external = NotchGeometry.ScreenCandidate(name: "Q27G2SG4B+", hasNotch: false, isMain: true, isBuiltin: false)
    private let second = NotchGeometry.ScreenCandidate(name: "DELL U2720Q", hasNotch: false, isMain: false, isBuiltin: false)

    @Test func withTheLidOpenTheBuiltInDisplayWithItsCameraHousingWins() {
        #expect(NotchGeometry.pick([external, builtin], preferredName: "", lidClosed: false) == 1)
    }

    @Test func withTheLidClosedTheBuiltInDisplayStillListedIsPassedOver() {
        // Right after the lid closes the built-in display can still be listed with its camera housing.
        #expect(NotchGeometry.pick([external, builtin], preferredName: "", lidClosed: true) == 0)
        #expect(NotchGeometry.pick([builtin, second, external], preferredName: "", lidClosed: true) == 2)
    }

    @Test func theDisplayNamedInSettingsWinsUnlessItIsTheClosedBuiltInOne() {
        #expect(NotchGeometry.pick([builtin, external, second], preferredName: "DELL U2720Q", lidClosed: false) == 2)
        #expect(NotchGeometry.pick([builtin, external], preferredName: "Built-in Retina Display", lidClosed: true) == 1)
        #expect(NotchGeometry.pick([builtin, external], preferredName: "Gone", lidClosed: false) == 0)
    }

    @Test func aClosedLidWithOnlyTheBuiltInDisplayListedStillGivesAScreen() {
        #expect(NotchGeometry.pick([builtin], preferredName: "", lidClosed: true) == 0)
        #expect(NotchGeometry.pick([], preferredName: "", lidClosed: false) == nil)
    }
}
