import AppKit
import SwiftUI

/// How wide each side of the collapsed notch is while a live activity shows. A side is as wide as what it holds:
/// the same margin from the shape's wall, the content, and the same gap to the camera, so the two sides look alike
/// however different their content is. The shape then moves sideways to keep the camera area over the camera
/// (see `NotchViewModel.collapsedShift`).
@MainActor
enum LiveEars {
    struct Sides: Equatable {
        var left: CGFloat
        var right: CGFloat

        static let zero = Sides(left: 0, right: 0)
    }

    /// From the shape's wall to the content: the top corner radius (6) and 7, which is the row's own padding.
    static let margin: CGFloat = 13
    /// Between the content and the camera area.
    static let gap: CGFloat = 6

    /// The artwork's and call icon's side.
    static func art(height: CGFloat) -> CGFloat { min(height - 14, 32) }

    static func sides(for content: CollapsedActivity.Content, art: CGFloat, base: CGFloat, at date: Date,
                      symmetric: Bool = false) -> Sides {
        var sides: Sides
        if content.left == .music && (content.right == .bars || content.right == .privacyDots) {
            // Artwork and visualizer keep the one ear they always had on each side.
            sides = Sides(left: base, right: base)
        } else {
            sides = Sides(left: margin + leftWidth(content, art: art) + gap,
                          right: margin + rightWidth(content, art: art, at: date) + gap)
        }
        if symmetric {
            // A line centred under the notch needs the shape centred on it.
            let wider = max(sides.left, sides.right)
            sides = Sides(left: wider, right: wider)
        }
        return sides
    }

    // MARK: Content

    static func leftWidth(_ content: CollapsedActivity.Content, art: CGFloat) -> CGFloat {
        switch content.left {
        case .call, .music: return art
        case .recording: return 8
        case .privacy:
            let symbols = [content.camera ? symbolWidth("video.fill", size: 10) : nil,
                           content.mic ? symbolWidth("mic.fill", size: 10) : nil].compactMap { $0 }
            return ceil(symbols.reduce(0, +) + 3 * CGFloat(max(0, symbols.count - 1)))
        case .download: return ceil(symbolWidth("arrow.down.circle.fill", size: 12))
        case .timer: return ceil(symbolWidth(content.timerSymbol, size: 12))
        }
    }

    static func rightWidth(_ content: CollapsedActivity.Content, art: CGFloat, at date: Date) -> CGFloat {
        let clock = content.clock.map { textWidth(clockText(for: $0, at: date)) } ?? 0
        switch content.right {
        case .recording, .timer:
            return clock
        case .call:
            return ceil(clock + (content.muted ? symbolWidth("mic.slash.fill", size: 9) + 3 : 0))
        case .privacyDots:
            let dots = (content.camera ? 1 : 0) + (content.mic ? 1 : 0)
            return CGFloat(6 * dots + 3 * max(0, dots - 1))
        case .download:
            return content.percent.map { textWidth("\($0)%") } ?? ceil(symbolWidth("ellipsis", size: 11))
        case .bars:
            return art - 2
        }
    }

    // MARK: Clocks

    /// The longest a clock counting up from nothing can read for as long as it keeps its format: minutes and seconds,
    /// then with hours, then with two digits of hours. Digits are monospaced, so every string of a format is this wide.
    nonisolated static func clockText(elapsed seconds: TimeInterval) -> String {
        seconds >= 36000 ? "10:00:00" : seconds >= 3600 ? "1:00:00" : "10:00"
    }

    /// What a clock is sized for: a countdown for the length it started from, so it never changes size on its way down;
    /// a clock counting up for its format.
    static func clockText(for clock: CollapsedActivity.Clock, at date: Date) -> String {
        clock.fixedLength.map { TimerModel.format($0) } ?? clockText(elapsed: clock.seconds(date))
    }

    /// When a clock counting up from one of `starts` next needs a longer format: an hour and ten hours in.
    nonisolated static func nextClockChange(after now: Date, startingAt starts: [Date]) -> Date? {
        starts.flatMap { start in [3600.0, 36000.0].map { start.addingTimeInterval($0) } }.filter { $0 > now }.min()
    }

    // MARK: Measuring

    private nonisolated static var textFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }

    nonisolated static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: textFont]).width)
    }

    nonisolated static func symbolWidth(_ name: String, size: CGFloat) -> CGFloat {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))?.size.width ?? 0
    }
}
