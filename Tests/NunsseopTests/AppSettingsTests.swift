import Foundation
import Testing
@testable import Nunsseop

@Suite(.serialized)
struct AppSettingsLoadTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let scratch = ScratchDefaults("AppSettings")
        defer { scratch.remove() }
        try body(scratch.defaults)
    }

    @Test(arguments: [(300.0, 540.0), (540.0, 540.0), (620.0, 620.0), (780.0, 780.0), (9999.0, 780.0)])
    func savedWidthIsClampedIntoRange(saved: Double, expected: Double) {
        withDefaults { defaults in
            defaults.set(saved, forKey: "expandedWidth")
            #expect(AppSettings.load("expandedWidth", default: 620, in: AppSettings.expandedWidthRange, from: defaults) == expected)
        }
    }

    @Test func savedHeightIsRaisedToTheMinimum() {
        withDefaults { defaults in
            defaults.set(1.0, forKey: "expandedHeight")
            #expect(AppSettings.load("expandedHeight", default: 196, in: AppSettings.expandedHeightRange, from: defaults) == 180)
            defaults.set(900.0, forKey: "expandedHeight")
            #expect(AppSettings.load("expandedHeight", default: 196, in: AppSettings.expandedHeightRange, from: defaults) == 260)
        }
    }

    @Test(arguments: [(5.0, 20.0), (50.0, 50.0), (500.0, 100.0)])
    func savedGlassTintIsClampedIntoRange(saved: Double, expected: Double) {
        withDefaults { defaults in
            defaults.set(saved, forKey: "glassTint")
            #expect(AppSettings.load("glassTint", default: 55, in: AppSettings.glassTintRange, from: defaults) == expected)
        }
    }

    @Test func unsetSizesUseTheDefault() {
        withDefaults { defaults in
            #expect(AppSettings.load("expandedWidth", default: 620, in: AppSettings.expandedWidthRange, from: defaults) == 620)
            #expect(AppSettings.load("glassTint", default: 55, in: AppSettings.glassTintRange, from: defaults) == 55)
        }
    }

    @Test func aDefaultOutsideTheRangeIsClampedToo() {
        withDefaults { defaults in
            #expect(AppSettings.load("expandedWidth", default: 100, in: AppSettings.expandedWidthRange, from: defaults) == 540)
        }
    }

    @Test func anUnsetSwitchTakesItsDefaultAndASetOneKeepsItsValue() {
        withDefaults { defaults in
            #expect(AppSettings.load("calendarEnabled", default: true, from: defaults))
            #expect(!AppSettings.load("downloadsToShelf", default: false, from: defaults))

            defaults.set(false, forKey: "calendarEnabled")
            defaults.set(true, forKey: "downloadsToShelf")
            #expect(!AppSettings.load("calendarEnabled", default: true, from: defaults))
            #expect(AppSettings.load("downloadsToShelf", default: false, from: defaults))
        }
    }

    @Test func aSavedZeroIsNotMistakenForUnset() {
        withDefaults { defaults in
            #expect(AppSettings.load("openDelay", default: 0.1, from: defaults) == 0.1)
            defaults.set(0.0, forKey: "openDelay")
            #expect(AppSettings.load("openDelay", default: 0.1, from: defaults) == 0)
        }
    }

    @Test func theSearchShortcutRoundTrips() {
        withDefaults { defaults in
            defaults.set(40, forKey: "searchHotKeyCode")
            defaults.set(256, forKey: "searchHotKeyModifiers")
            defaults.set("K", forKey: "searchHotKeyName")
            #expect(AppSettings.loadSearchHotKey(from: defaults) == HotKeyCombo(keyCode: 40, modifiers: 256, key: "K"))
        }
    }

    @Test func withoutASavedShortcutNameTheDefaultShortcutIsUsed() {
        withDefaults { defaults in
            defaults.set(40, forKey: "searchHotKeyCode")
            #expect(AppSettings.loadSearchHotKey(from: defaults) == .defaultSearch)
        }
    }
}

struct AppSettingsTabOrderTests {
    private let others = NotchTab.allCases.filter { $0 != .home }

    @Test func savedTabsComeFirstAndNewTabsAreAppendedInTheirUsualOrder() {
        let order = AppSettings.orderedTabs(saved: ["shelf", "bogus", "timer"])
        #expect(Array(order.prefix(2)) == [.shelf, .timer])
        #expect(Array(order.dropFirst(2)) == others.filter { $0 != .shelf && $0 != .timer })
    }

    @Test func noSavedOrderGivesEveryTabOnceWithoutHome() {
        #expect(AppSettings.orderedTabs(saved: []) == others)
    }

    @Test func homeInTheSavedOrderIsIgnored() {
        let order = AppSettings.orderedTabs(saved: ["home", "notes"])
        #expect(order.first == .notes)
        #expect(!order.contains(.home))
        #expect(order.count == others.count)
    }

    @Test func aTabListedTwiceIsShownOnce() {
        let order = AppSettings.orderedTabs(saved: ["timer", "timer", "shelf"])
        #expect(order.filter { $0 == .timer }.count == 1)
        #expect(Array(order.prefix(2)) == [.timer, .shelf])
        #expect(order.count == others.count)
    }

    @Test func draggingATabDownPutsItBeforeTheDestination() {
        let moved = AppSettings.moved(from: [0], to: 3, in: others)
        #expect(Array(moved.prefix(3)) == [others[1], others[2], others[0]])
        #expect(Set(moved) == Set(others) && moved.count == others.count)
    }

    @Test func draggingATabUpOrToTheEnd() throws {
        let last = try #require(others.last)
        #expect(AppSettings.moved(from: [others.count - 1], to: 0, in: others).first == last)
        #expect(AppSettings.moved(from: [0], to: others.count, in: others).last == others[0])
    }

    @Test func droppingATabWhereItIsChangesNothing() {
        #expect(AppSettings.moved(from: [2], to: 2, in: others) == others)
        #expect(AppSettings.moved(from: [2], to: 3, in: others) == others)
    }
}

@Suite struct TabReorderTests {
    /// The grid of the Settings window: two tabs to a row, 14 tabs.
    private let cell = CGSize(width: 170, height: 36)

    private func target(from: Int, _ dx: CGFloat, _ dy: CGFloat) -> Int {
        TabReorder.target(from: from, offset: CGSize(width: dx, height: dy), cell: cell, count: 14)
    }

    @Test func aTabLandsOnTheCellItsMiddleIsOver() {
        #expect(target(from: 3, 0, 0) == 3)
        #expect(target(from: 3, 80, 17) == 3)
        // A little more than half a row down: the cell below, in the same column.
        #expect(target(from: 3, 0, 19) == 5)
        // Across to the other column, and across and down.
        #expect(target(from: 2, 100, 0) == 3)
        #expect(target(from: 2, 100, 40) == 5)
        #expect(target(from: 5, -100, -40) == 2)
    }

    @Test func aTabDraggedPastTheEdgesStaysInTheGridAndHomeStaysFirst() {
        #expect(target(from: 2, -500, -500) == 1)
        #expect(target(from: 3, -500, -500) == 1)
        #expect(target(from: 4, 500, 500) == 13)
        // With an odd number of tabs the last row has one cell: its right-hand slot does not exist.
        #expect(TabReorder.target(from: 10, offset: CGSize(width: 500, height: 500), cell: cell, count: 13) == 12)
    }

    @Test func theTabsPassedStepAsideTowardsWhereItCameFrom() {
        // Dragged on from slot 1 to 3: slots 2 and 3 move back one.
        #expect((0..<6).map { TabReorder.shift($0, from: 1, target: 3) } == [0, 0, -1, -1, 0, 0])
        // Dragged back from 4 to 2: slots 2 and 3 move on one.
        #expect((0..<6).map { TabReorder.shift($0, from: 4, target: 2) } == [0, 0, 1, 1, 0, 0])
        #expect((0..<6).map { TabReorder.shift($0, from: nil, target: nil) } == [0, 0, 0, 0, 0, 0])
    }

    @Test func aDropReordersTheTabsAfterHome() {
        let order = AppSettings.orderedTabs(saved: [])
        func dropped(_ from: Int, on to: Int) -> [NotchTab] {
            let move = TabReorder.move(from: from, to: to)
            return AppSettings.moved(from: move.source, to: move.destination, in: order)
        }
        // Grid slot 3 holds the third tab after Home; dropped on slot 5 it ends up there, and the two it passed move back a slot.
        #expect(dropped(3, on: 5) == [order[0], order[1], order[3], order[4], order[2]] + order[5...])
        #expect(dropped(5, on: 2) == [order[0], order[4], order[1], order[2], order[3]] + order[5...])
        #expect(dropped(4, on: 4) == order)
    }
}
