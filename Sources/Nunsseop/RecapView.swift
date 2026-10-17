import AppKit
import SwiftUI

/// The words of the recap, from a `WeekRecap`.
enum RecapText {
    static var title: String { String(localized: "What your brow saw last week") }

    /// "Oct 13 – 19": the week's first and last day.
    static func range(_ week: DateInterval, calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        return (week.start..<last).formatted(.interval.month(.abbreviated).day())
    }

    /// "21h 40m", in whole minutes.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return String(localized: "\(rest)m") }
        return rest == 0 ? String(localized: "\(hours)h") : "\(String(localized: "\(hours)h")) \(String(localized: "\(rest)m"))"
    }

    /// How the working time compares with the week before; less than five minutes either way is the same.
    static func change(_ recap: WeekRecap) -> String {
        guard recap.workingBefore > 0 else { return String(localized: "Nothing the week before") }
        let difference = recap.working - recap.workingBefore
        if abs(difference) < 5 * 60 { return String(localized: "Same as the week before") }
        return difference > 0 ? String(localized: "↑ \(duration(difference)) vs the week before")
            : String(localized: "↓ \(duration(-difference)) vs the week before")
    }

    /// "Claude Code 31 · Codex 15": the tools that have a count.
    static func perTool(_ counts: [(name: String, value: String, count: Int)]) -> String {
        counts.filter { $0.count > 0 }.map { "\($0.name) \($0.value)" }.joined(separator: " · ")
    }

    static func sessions(_ recap: WeekRecap) -> String {
        perTool([(AgentKind.claude.displayName, recap.claudeSessions.formatted(), recap.claudeSessions),
                 (AgentKind.codex.displayName, recap.codexSessions.formatted(), recap.codexSessions)])
    }

    /// "12.9M": up to three digits.
    static func compact(_ tokens: Int) -> String { tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))) }

    static func tokens(_ recap: WeekRecap) -> String {
        perTool([("Claude", compact(recap.claudeTokens), recap.claudeTokens), ("Codex", compact(recap.codexTokens), recap.codexTokens)])
    }

    static func lines(_ recap: WeekRecap) -> String { "+\(recap.added.formatted()) \u{2212}\(recap.removed.formatted())" }

    static func files(_ recap: WeekRecap) -> String {
        recap.files == 1 ? String(localized: "1 file") : String(localized: "\(recap.files) files")
    }

    static func share(_ recap: WeekRecap) -> String? {
        recap.topProject.map { String(localized: "\($0.share.formatted(.percent.precision(.fractionLength(0)))) of the time") }
    }

    /// "Thursday night", from the day and the hour it began.
    static func dayPart(_ date: Date, calendar: Calendar = .current) -> String {
        let day = date.formatted(.dateTime.weekday(.wide))
        switch calendar.component(.hour, from: date) {
        case 5..<12: return String(localized: "\(day) morning")
        case 12..<18: return String(localized: "\(day) afternoon")
        case 18..<22: return String(localized: "\(day) evening")
        default: return String(localized: "\(day) night")
        }
    }

    static func longest(_ longest: WeekRecap.Longest) -> String {
        [dayPart(longest.start), longest.title].compactMap { $0 }.joined(separator: " · ")
    }

    static func weekday(_ index: Int, of week: DateInterval, calendar: Calendar = .current) -> String {
        (calendar.date(byAdding: .day, value: index, to: week.start) ?? week.start).formatted(.dateTime.weekday(.wide))
    }

    /// "Busiest day: Wednesday", or the label alone when no day stands out.
    static func busiest(_ recap: WeekRecap) -> String {
        recap.busiestDay.map { String(localized: "Busiest day: \(weekday($0, of: recap.week))") } ?? String(localized: "Busiest day")
    }

    /// M T W T F S S, Monday first, as the language writes them.
    static var weekdayInitials: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return (1...7).map { symbols[$0 % 7] }
    }

    static func projects(_ count: Int) -> String {
        count == 1 ? String(localized: "1 project") : String(localized: "\(count) projects")
    }
}

/// The recap in the expanded notch: the title and its buttons, then the stats as two rows of tiles.
struct RecapView: View {
    /// The room it is laid out for: the height of the default notch is a little short for two rows of tiles.
    static let minimumSize = CGSize(width: 660, height: 250)

    @ObservedObject var card: RecapCard

    var body: some View {
        let week = card.recap?.week ?? WeekRecap.lastWeek(before: .now, calendar: .current)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RecapText.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(RecapText.range(week)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 8)
                if let recap = card.recap, !recap.isEmpty {
                    PanelAction(title: saveTitle, symbol: "square.and.arrow.down", action: { card.saveImage() })
                }
                PanelAction(title: "Close", key: "esc", action: card.close)
            }
            if let recap = card.recap {
                if recap.isEmpty { empty } else { RecapStats(recap: recap) }
            } else {
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private var saveTitle: LocalizedStringKey {
        switch card.saved {
        case nil: "Save image"
        case .saved: "Saved to Downloads"
        case .failed: "Couldn't save the image"
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5)).accessibilityHidden(true)
            Text("A quiet week").font(.system(size: 13, weight: .semibold))
            Text("No Claude Code or Codex sessions last week, so there is nothing to look back on.")
                .font(.system(size: 11)).foregroundStyle(PanelInk.hint).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The AI tab's way back to the recap.
struct RecapLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 9)).accessibilityHidden(true)
                Text("Last week").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.65))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .layoutPriority(1)
    }
}

/// Four tiles, then the most worked project, the longest session and the busiest day.
struct RecapStats: View {
    let recap: WeekRecap

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                RecapTile(label: "Agent working time", value: RecapText.duration(recap.working), sub: RecapText.change(recap))
                RecapTile(label: "Sessions", value: recap.sessions.formatted(), sub: RecapText.sessions(recap))
                RecapTile(label: "Lines changed", value: RecapText.lines(recap), sub: RecapText.files(recap))
                RecapTile(label: "Tokens", value: RecapText.compact(recap.tokens), sub: RecapText.tokens(recap))
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                RecapTile(label: "Most worked project", value: recap.topProject?.name ?? "\u{2014}", sub: RecapText.share(recap) ?? "")
                RecapTile(label: "Longest session", value: recap.longest.map { RecapText.duration($0.duration) } ?? "\u{2014}",
                          sub: recap.longest.map(RecapText.longest) ?? "")
                DayBars(recap: recap)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RecapTile: View {
    let label: LocalizedStringKey
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Text(verbatim: value).font(.system(size: 17, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(verbatim: sub).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

/// Seven small bars, Monday to Sunday, with the busiest one highlighted.
private struct DayBars: View {
    let recap: WeekRecap

    var body: some View {
        let top = recap.days.max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text(RecapText.busiest(recap)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<7, id: \.self) { day in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(day == recap.busiestDay ? 0.9 : 0.4))
                            .frame(width: 14, height: top > 0 ? 30 * recap.days[day] / top + 2 : 2)
                        Text(RecapText.weekdayInitials[day]).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(RecapText.busiest(recap)))
    }
}

/// The picture to save: a black portrait card with the week's big numbers. Project names stay out of it.
enum RecapImage {
    static let size = CGSize(width: 1080, height: 1920)

    @MainActor static func png(_ recap: WeekRecap) -> Data? {
        let renderer = ImageRenderer(content: RecapImageView(recap: recap))
        renderer.scale = 1
        return renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    /// Writes "Nunsseop recap 2026-10-20.png" into `folder`, or "… 2.png" and on when that name is taken.
    static func write(_ data: Data, to folder: URL, now: Date, calendar: Calendar = .current) throws -> URL {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        let name = String(format: "Nunsseop recap %04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        var number = 1
        while true {
            let url = folder.appendingPathComponent(number == 1 ? "\(name).png" : "\(name) \(number).png")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }
}

struct RecapImageView: View {
    let recap: WeekRecap

    var body: some View {
        VStack(spacing: 0) {
            EyebrowArch(lift: 1).fill(Color(red: 0.957, green: 0.957, blue: 0.945)).frame(width: 340, height: 136).padding(.top, 200)
            Text(RecapText.title).font(.system(size: 68, weight: .bold)).multilineTextAlignment(.center).padding(.top, 64)
            Text(RecapText.range(recap.week)).font(.system(size: 38)).foregroundStyle(.white.opacity(0.5)).padding(.top, 18)
            VStack(spacing: 44) {
                value(RecapText.duration(recap.working), "Agent working time")
                value(recap.sessions.formatted(), "Sessions")
                value(RecapText.lines(recap), "Lines changed")
                value(recap.busiestDay.map { RecapText.weekday($0, of: recap.week) } ?? "\u{2014}", "Busiest day")
                value(RecapText.projects(recap.projects.count), "Names hidden")
            }
            .padding(.top, 96)
            Spacer(minLength: 0)
            Text(verbatim: "Nunsseop").font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.4)).padding(.bottom, 84)
        }
        .padding(.horizontal, 72)
        .frame(width: RecapImage.size.width, height: RecapImage.size.height)
        .background(.black)
        .foregroundStyle(.white)
    }

    private func value(_ text: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: text).font(.system(size: 96, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 36)).foregroundStyle(.white.opacity(0.55))
        }
    }
}
