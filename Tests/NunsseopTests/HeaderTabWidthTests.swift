import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

/// The header keeps room for the current tab's title beside its icon, whichever tab that is, so choosing another moves nothing.
/// These measure real fonts and SF Symbols, so they depend on the system's own, deliberately.
@MainActor
struct HeaderTabWidthTests {
    private func width(_ tab: NotchTab, selected: Bool, badge: Int = 0) -> CGFloat {
        NSHostingView(rootView: TabButton(tab: tab, selected: selected, badge: badge) {}).fittingSize.width
    }

    @Test func aBareTabIsAnIconButton() {
        for tab in NotchTab.allCases { #expect(width(tab, selected: false) == 26, "\(tab)") }
    }

    @Test func theCurrentTabsCapsuleFitsWhatTheHeaderReservesForEveryTab() {
        let reserved = NotchViewModel.tabLabelWidth(NotchTab.allCases)
        for tab in NotchTab.allCases {
            let extra = width(tab, selected: true, badge: 12) - 26
            #expect(extra > 0, "\(tab)")
            #expect(extra <= reserved, "\(tab): \(extra) of \(reserved)")
        }
    }
}
