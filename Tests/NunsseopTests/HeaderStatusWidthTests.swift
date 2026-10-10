import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

/// The header reserves 66 for the battery badge and 50 for the weather chip, each including the 6 the row puts
/// between its items; what is drawn has to fit what is reserved.
/// These measure real fonts and SF Symbols, so they depend on the system's own, deliberately.
@MainActor
struct HeaderStatusWidthTests {
    private let spacing: CGFloat = 6

    private func width<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    @Test func theBatteryBadgeFitsItsReservedWidthAtEveryDigitCount() {
        for state in [PowerState(percent: 5, isCharging: false, onAC: false),
                      PowerState(percent: 88, isCharging: true, onAC: true),
                      PowerState(percent: 100, isCharging: true, onAC: true),
                      PowerState(percent: 100, isCharging: false, onAC: false)] {
            let w = width(BatteryBadge(state: state))
            #expect(w > 20, "\(state): \(w)")
            #expect(w <= 66 - spacing, "\(state): \(w)")
        }
    }

    @Test func theWeatherChipFitsItsReservedWidthForEverySymbolWithOneAndTwoDigitTemperatures() {
        for code in [0, 1, 3, 45, 51, 61, 71, 95, 99] {
            for temperature in [8.0, 35] {
                let current = WeatherModel.Current(place: "Seoul", temperature: temperature, high: 40, low: -20, code: code)
                let w = width(WeatherChip(weather: current))
                #expect(w > 20, "code \(code), \(temperature)°: \(w)")
                #expect(w <= 50 - spacing, "code \(code), \(temperature)°: \(w)")
            }
        }
    }
}
