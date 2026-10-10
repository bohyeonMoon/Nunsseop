import SwiftUI
import Testing
@testable import Nunsseop

@MainActor
struct LiveActivityPrecedenceTests {
    private func left(call: Bool = false, playing: Bool = false, recording: Bool = false, privacy: Bool = false,
                      download: Bool = false) -> CollapsedActivity.LeftIcon {
        CollapsedActivity.leftIcon(inCall: call, playing: playing, recording: recording, privacyActive: privacy, downloading: download)
    }

    private func right(recording: Bool = false, call: Bool = false, privacy: Bool = false, timer: Bool = false,
                       playing: Bool = false, download: Bool = false) -> CollapsedActivity.RightContent {
        CollapsedActivity.rightContent(recording: recording, inCall: call, privacyActive: privacy, timerShown: timer,
                                       playing: playing, downloading: download)
    }

    @Test func theLeftIconsRunCallMusicRecordingPrivacyDownloadTimer() {
        #expect(left(call: true, playing: true, recording: true, privacy: true, download: true) == .call)
        #expect(left(playing: true, recording: true, privacy: true, download: true) == .music)
        #expect(left(recording: true, privacy: true, download: true) == .recording)
        #expect(left(privacy: true, download: true) == .privacy)
        #expect(left(download: true) == .download)
        #expect(left() == .timer)
    }

    @Test func theRightSideRunsRecordingCallPrivacyTimerDownloadBars() {
        #expect(right(recording: true, call: true, privacy: true, timer: true, playing: true, download: true) == .recording)
        #expect(right(call: true, privacy: true, timer: true, playing: true, download: true) == .call)
        #expect(right(privacy: true, timer: false, playing: true, download: true) == .privacyDots)
        #expect(right(privacy: false, timer: true, playing: true, download: true) == .timer)
        #expect(right(download: true) == .download)
        #expect(right(playing: true) == .bars)
        #expect(right() == .bars)
    }

    @Test func privacyDotsOnTheRightNeedMusicAndNoRunningTimer() {
        #expect(right(privacy: true, playing: false) == .bars)
        #expect(right(privacy: true, timer: true, playing: true) == .timer)
    }

    @Test func aRecordingKeepsItsTimeOnTheRightWhileACallTakesTheLeftIcon() {
        #expect(left(call: true, recording: true) == .call)
        #expect(right(recording: true, call: true) == .recording)
    }

    @Test func aRunningTimerOutranksADownloadOnTheRight() {
        #expect(right(timer: true, download: true) == .timer)
    }
}

struct EarWidthTests {
    private func ear(height: CGFloat = 32, compact: Bool = false, call: Bool = false, muted: Bool = false,
                     text: Bool = false) -> CGFloat {
        NotchViewModel.earWidth(height: height, compact: compact, inCall: call, muted: muted, needsText: text)
    }

    @Test func theEarIsThePanelHeightPlusSix() {
        #expect(ear(height: 32) == 38)
        #expect(ear(height: 18) == 24)
    }

    @Test func theCompactEarIsSeventyPercentOfTheHeight() {
        #expect(abs(ear(height: 32, compact: true) - 22.4) < 0.001)
        #expect(abs(ear(height: 18, compact: true) - 12.6) < 0.001)
    }

    @Test func aTimerRecordingOrDownloadNeedsRoomForItsText() {
        #expect(ear(text: true) == 50)
        #expect(ear(compact: true, text: true) == 50)
        // A taller ear is not made smaller.
        #expect(ear(height: 60, text: true) == 66)
    }

    @Test func aCallNeedsRoomForItsClockAndAMuteIcon() {
        #expect(ear(call: true) == 60)
        #expect(ear(call: true, muted: true) == 74)
        #expect(ear(compact: true, call: true, text: true) == 60)
    }
}

@MainActor
struct IdleValueTests {
    @Test func batteryIsRedAtTwentyPercentOrLessOnBattery() {
        let low = NotchViewModel.batteryValue(PowerState(percent: 20, isCharging: false, onAC: false))
        #expect(low.tint == .red)
        #expect(low.text == "20%")
        #expect(NotchViewModel.batteryValue(PowerState(percent: 21, isCharging: false, onAC: false)).tint == .white)
        #expect(NotchViewModel.batteryValue(PowerState(percent: 20, isCharging: false, onAC: true)).tint == .white)
    }

    @Test func batterySymbolFollowsTheBandsOrShowsCharging() {
        #expect(NotchViewModel.batteryValue(PowerState(percent: 50, isCharging: false, onAC: false)).symbol == "battery.50percent")
        #expect(NotchViewModel.batteryValue(PowerState(percent: 50, isCharging: true, onAC: true)).symbol == "battery.100percent.bolt")
        // Plugged in but done charging shows the level, not the bolt.
        #expect(NotchViewModel.batteryValue(PowerState(percent: 100, isCharging: false, onAC: true)).symbol == "battery.100percent")
    }

    @Test func claudeIsOrangeAndCodexWhiteUntilTheyRunLow() {
        #expect(NotchViewModel.aiValue(.claude, left: 80).tint == .orange)
        #expect(NotchViewModel.aiValue(.claude, left: 80).symbol == "sparkles")
        #expect(NotchViewModel.aiValue(.codex, left: 80).tint == .white)
        #expect(NotchViewModel.aiValue(.codex, left: 80).symbol == "terminal")
        #expect(NotchViewModel.aiValue(.codex, left: 80).text == "80%")
    }

    @Test func aLimitTurnsRedBelowFifteenPercent() {
        #expect(NotchViewModel.aiValue(.claude, left: 14).tint == .red)
        #expect(NotchViewModel.aiValue(.codex, left: 14).tint == .red)
        #expect(NotchViewModel.aiValue(.claude, left: 15).tint == .orange)
        #expect(NotchViewModel.aiValue(.codex, left: 15).tint == .white)
        #expect(NotchViewModel.aiValue(.claude, left: 0).text == "0%")
    }

    @Test func weatherRoundsTheTemperatureToAWholeDegree() {
        func text(_ temperature: Double) -> String {
            NotchViewModel.weatherValue(WeatherModel.Current(place: "Seoul", temperature: temperature, high: 30, low: 10, code: 0)).text
        }
        #expect(text(20.4) == "20°")
        #expect(text(20.5) == "21°")
        #expect(text(-0.4) == "0°")
        #expect(text(-0.6) == "-1°")
    }

    @Test func weatherUsesTheConditionsSymbolInItsOwnColours() {
        let value = NotchViewModel.weatherValue(WeatherModel.Current(place: "Seoul", temperature: 20, high: 30, low: 10, code: 0))
        #expect(value.symbol == WeatherModel.symbol(for: 0))
        #expect(value.tint == nil)
    }
}
