import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

/// The header reserves 66 for the battery badge and room for the weather chip, each including the 6 the row puts
/// between its items; what is drawn has to fit what is reserved, with the weather chip leaving 2 to spare for
/// another system's font metrics.
/// These measure real fonts and SF Symbols, so they depend on the system's own, deliberately.
@MainActor
struct HeaderStatusWidthTests {
    private let spacing: CGFloat = 6
    private let weatherReserved = NotchViewModel.headerStatusWidth(battery: false, weather: true)
        - NotchViewModel.headerStatusWidth(battery: false, weather: false)

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

    /// Every code the app maps to a symbol, and one it doesn't.
    private let weatherCodes = [0, 1, 2, 3, 45, 48] + Array(51...57) + Array(61...67) + Array(71...77)
        + Array(80...82) + [85, 86] + Array(95...99) + [100]
    /// One and two digits, negative ones, and a Fahrenheit reading over a hundred.
    private let temperatures: [Double] = [0, 8, 35, -5, -12, -40, 104]

    @Test func theWeatherChipFitsItsReservedWidthForEverySymbolAndTemperature() {
        for code in weatherCodes {
            for temperature in temperatures {
                let current = WeatherModel.Current(place: "Seoul", temperature: temperature, high: 40, low: -20, code: code)
                let w = width(WeatherChip(weather: current))
                #expect(w > 20, "code \(code), \(temperature)°: \(w)")
                #expect(w <= weatherReserved - spacing - 2, "code \(code), \(temperature)°: \(w)")
            }
        }
    }
}
