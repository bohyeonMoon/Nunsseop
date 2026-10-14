import Foundation
import Testing
@testable import Nunsseop

struct DetailSelectionTests {
    private let ids = ["a", "b", "c", "d"]

    @Test func theFirstItemShowsWhenNothingIsHoveredOrChosen() {
        #expect(DetailSelection<String>().current(in: ids) == "a")
        #expect(DetailSelection<String>().current(in: []) == nil)
    }

    @Test func thePointerWinsWhileItIsOverARowAndLeavingFallsBack() {
        var selection = DetailSelection<String>()
        selection.hover("c", inside: true)
        #expect(selection.current(in: ids) == "c")
        selection.hover("c", inside: false)
        #expect(selection.current(in: ids) == "a")
    }

    @Test func leavingAnotherRowDoesNotClearTheOneNowUnderThePointer() {
        var selection = DetailSelection<String>()
        selection.hover("b", inside: true)
        selection.hover("c", inside: true)
        selection.hover("b", inside: false)
        #expect(selection.current(in: ids) == "c")
    }

    @Test func theArrowKeysMoveFromWhatIsShownAndStopAtTheEnds() {
        var selection = DetailSelection<String>()
        selection.move(1, in: ids)
        #expect(selection.current(in: ids) == "b")
        selection.move(1, in: ids); selection.move(1, in: ids); selection.move(1, in: ids)
        #expect(selection.current(in: ids) == "d")
        selection.move(-1, in: ids)
        #expect(selection.current(in: ids) == "c")
        selection.move(-9, in: ids)
        #expect(selection.current(in: ids) == "a")
    }

    @Test func aKeyStartsFromTheHoveredRowAndEndsThePointersClaim() {
        var selection = DetailSelection<String>()
        selection.hover("b", inside: true)
        selection.move(1, in: ids)
        #expect(selection.current(in: ids) == "c")
        selection.hover("b", inside: false)
        #expect(selection.current(in: ids) == "c")
    }

    @Test func anItemThatLeftTheListIsNotShown() {
        var selection = DetailSelection<String>()
        selection.hover("c", inside: true)
        #expect(selection.current(in: ["a", "b"]) == "a")
        selection.move(1, in: ids)
        #expect(selection.current(in: ["a", "b"]) == "a")
    }
}

@MainActor
struct PanelKeysTests {
    @Test func aKeyIsLeftAloneWhenNoTabListens() {
        #expect(!PanelKeys.move(1))
    }

    @Test func aListeningTabTakesTheKeyAndLeavingReleasesIt() {
        var steps: [Int] = []
        let watching = PanelKeys.moves.sink { steps.append($0) }
        PanelKeys.listen()
        #expect(PanelKeys.move(-1))
        PanelKeys.stopListening()
        #expect(!PanelKeys.move(1))
        #expect(steps == [-1])
        watching.cancel()
    }
}

struct PowerStateLowTests {
    @Test func lowMeansTwentyPercentOrLessOnBattery() {
        #expect(PowerState(percent: 20, isCharging: false, onAC: false).isLow)
        #expect(!PowerState(percent: 21, isCharging: false, onAC: false).isLow)
        #expect(!PowerState(percent: 5, isCharging: true, onAC: true).isLow)
    }

    @Test func aPeripheralIsLowAtFifteenPercent() {
        #expect(PeripheralBattery(name: "Mouse", percent: 15, kind: .mouse).isLow)
        #expect(!PeripheralBattery(name: "Mouse", percent: 16, kind: .mouse).isLow)
    }
}

struct HomeColumnTests {
    @Test func theRightColumnShowsAWholeWeekWhereItHasRoom() {
        #expect(HomePanels.column(for: 556).days == 7)
        #expect(HomePanels.column(for: 556).width == 280)
        #expect(HomePanels.column(for: 476).days == 5)
        #expect(HomePanels.column(for: 476).width == 214)
    }
}
