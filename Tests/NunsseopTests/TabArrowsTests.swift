import CoreGraphics
import Testing
@testable import Nunsseop

struct TabArrowsTests {
    @Test func anArrowShowsOnlyWhileATabLiesPastThatEnd() {
        // Scrolled to the end: the last tab ends at the strip's edge, so no arrow covers it.
        #expect(!TabArrows.hidesAfter(lastMaxX: 300, width: 300))
        #expect(!TabArrows.hidesAfter(lastMaxX: 300.6, width: 300))
        #expect(TabArrows.hidesAfter(lastMaxX: 330, width: 300))
        #expect(!TabArrows.hidesBefore(firstMinX: 0))
        #expect(!TabArrows.hidesBefore(firstMinX: -0.6))
        #expect(TabArrows.hidesBefore(firstMinX: -40))
    }
}
