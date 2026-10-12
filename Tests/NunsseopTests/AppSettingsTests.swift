import Foundation
import Testing
@testable import Nunsseop

@Suite(.serialized)
struct AppSettingsLoadTests {
    private static let suiteName = "NunsseopTests.AppSettings"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        try body(defaults)
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
    @Test func aRowLandsOnTheSlotItsMiddleIsOver() {
        #expect(TabReorder.target(from: 2, offset: 0, rowHeight: 36, count: 8) == 2)
        #expect(TabReorder.target(from: 2, offset: 17, rowHeight: 36, count: 8) == 2)
        #expect(TabReorder.target(from: 2, offset: 19, rowHeight: 36, count: 8) == 3)
        #expect(TabReorder.target(from: 2, offset: -60, rowHeight: 36, count: 8) == 0)
    }

    @Test func aRowDraggedPastEitherEndStaysInTheList() {
        #expect(TabReorder.target(from: 1, offset: -500, rowHeight: 36, count: 8) == 0)
        #expect(TabReorder.target(from: 6, offset: 500, rowHeight: 36, count: 8) == 7)
    }

    @Test func theRowsPassedStepAsideTowardsWhereItCameFrom() {
        // Dragged down from 1 to 3: rows 2 and 3 move up one.
        #expect((0..<6).map { TabReorder.shift($0, from: 1, target: 3) } == [0, 0, -1, -1, 0, 0])
        // Dragged up from 4 to 2: rows 2 and 3 move down one.
        #expect((0..<6).map { TabReorder.shift($0, from: 4, target: 2) } == [0, 0, 1, 1, 0, 0])
        #expect((0..<6).map { TabReorder.shift($0, from: nil, target: nil) } == [0, 0, 0, 0, 0, 0])
    }
}
