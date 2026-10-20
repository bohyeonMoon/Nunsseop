import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

private func busyWeek() -> WeekRecap {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
    var recap = WeekRecap(week: DateInterval(start: monday, end: calendar.date(byAdding: .day, value: 7, to: monday)!))
    recap.working = 121 * 3_600 + 55 * 60
    recap.workingBefore = 100 * 3_600
    recap.claudeSessions = 312
    recap.codexSessions = 156
    recap.claudeTokens = 123_400_000
    recap.codexTokens = 56_700_000
    recap.added = 123_456
    recap.removed = 98_765
    recap.files = 1_834
    recap.projects = ["A-very-long-project-folder-name-that-goes-on": 3_600, "Secret-Project-X": 1_800, "dotfiles": 600]
    recap.longest = .init(duration: 11 * 3_600 + 59 * 60, start: monday.addingTimeInterval(3 * 86_400 + 22 * 3_600),
                          title: "Refactor the whole login flow and then some more of it besides")
    recap.days = [4, 7, 10, 5.5, 8, 1, 2.5].map { $0 * 3_600 }
    return recap
}

struct RecapRenderTests {
    /// The notch's content area at the size the recap is laid out for: the width less the insets, and the height less the header band
    /// (32), the gap under it (8), the title row (24 and 8) and the bottom padding (14).
    private static let width = RecapView.minimumSize.width - 2 * NotchViewModel.headerInset
    private static let height = RecapView.minimumSize.height - 32 - 8 - 24 - 8 - 14

    @MainActor
    private func lit(_ view: some View) -> (left: CGFloat, right: CGFloat, bottom: CGFloat)? {
        let size = CGSize(width: Self.width + 2 * NotchViewModel.headerInset, height: 400)
        let rep = EarRender.pixels(view.padding(.horizontal, NotchViewModel.headerInset).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black), width: size.width, height: size.height)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var left = Int.max, right = -1, bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.03 || c.blueComponent > 0.03 else { continue }
                left = min(left, x)
                right = max(right, x)
                bottom = max(bottom, y)
            }
        }
        return right < 0 ? nil : (CGFloat(left) / scale, CGFloat(right + 1) / scale, CGFloat(bottom + 1) / scale)
    }

    @MainActor @Test func theTilesStayInsideTheNotchEvenForTheBusiestWeek() throws {
        let edges = try #require(lit(RecapStats(recap: busyWeek())))
        let margin = NotchViewModel.headerInset
        #expect(edges.left >= margin - 0.5, Comment(rawValue: "\(edges.left)"))
        #expect(edges.right <= margin + Self.width + 1, Comment(rawValue: "\(edges.right)"))
        #expect(edges.bottom <= Self.height, Comment(rawValue: "the tiles end at \(edges.bottom) of \(Self.height)"))
    }

    @MainActor @Test func theTilesFillTheRowsWhateverTheWeekHolds() throws {
        var quiet = busyWeek()
        quiet.projects = [:]
        quiet.longest = nil
        quiet.days = [TimeInterval](repeating: 0, count: 7)
        quiet.working = 0
        quiet.workingBefore = 0
        let edges = try #require(lit(RecapStats(recap: quiet)))
        #expect(edges.bottom <= Self.height, Comment(rawValue: "\(edges.bottom)"))
        // A tile's background reaches the content's right edge, so the rows line up whatever is inside.
        #expect(edges.right >= NotchViewModel.headerInset + Self.width - 1.5, Comment(rawValue: "\(edges.right)"))
    }

    @MainActor @Test func theSavedImageKeepsProjectNamesOutAndSaysHowManyThereWere() throws {
        let busy = busyWeek()
        var renamed = busy
        renamed.projects = ["One": 3_600, "Two": 1_800, "Three": 600]
        var fewer = busy
        fewer.projects = ["One": 3_600]
        let image = try #require(RecapImage.png(busy))
        // The same week under other names is the same picture; one project fewer is not.
        #expect(image == RecapImage.png(renamed))
        #expect(image != RecapImage.png(fewer))
        let size = try #require(NSBitmapImageRep(data: image))
        #expect(size.pixelsWide == 1080 && size.pixelsHigh == 1920)
    }
}
