import AppKit
import Foundation
import Testing
@testable import Nunsseop

private let seoul: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}()

private func date(_ day: Int, _ hour: Int = 12) -> Date {
    seoul.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
}

private func recap(sessions: Int = 3, days: Int = 12) -> WeekRecap {
    var recap = WeekRecap(week: WeekRecap.lastWeek(before: date(days), calendar: seoul))
    recap.claudeSessions = sessions
    recap.working = 3_600
    return recap
}

/// A card with the week's recap made up, counting how often it was read.
@MainActor
private final class CardRig {
    let scratch = ScratchDefaults("RecapCard\(UUID().uuidString.prefix(8))")
    let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-recap-downloads-\(UUID().uuidString.prefix(8))")
    let reads = ReadCount()
    var revealed: [URL] = []
    var card: RecapCard!

    final class ReadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    init(result: WeekRecap = recap()) {
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let reads = reads
        card = RecapCard(defaults: scratch.defaults, downloads: downloads, read: { _ in reads.bump(); return result },
                         reveal: { [unowned self] in revealed.append($0) })
    }

    deinit {
        scratch.remove()
        try? FileManager.default.removeItem(at: downloads)
    }

    /// Waits for a read in the background to finish.
    func settle() async {
        for _ in 0..<400 where card.isReading { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func open(on day: Int, enabled: Bool = true, canShow: @escaping () -> Bool = { true }) async {
        card.notchOpened(enabled: enabled, canShow: canShow, now: date(day))
        await settle()
    }
}

@MainActor
struct RecapCardTests {
    @Test func aWeekHasTheKeyOfItsMonday() {
        let key = RecapCard.weekKey(now: date(19, 0), calendar: seoul)
        #expect(key == "2026-10-19")
        for day in 19...25 { #expect(RecapCard.weekKey(now: date(day, 23), calendar: seoul) == key, Comment(rawValue: "\(day)")) }
        #expect(RecapCard.weekKey(now: date(18, 23), calendar: seoul) == "2026-10-12")
        #expect(RecapCard.weekKey(now: date(26, 0), calendar: seoul) == "2026-10-26")
    }

    @Test func theSeenKeyIsStoredUnderItsDocumentedName() {
        #expect(RecapCard.seenKey == "recapSeenWeek")
    }

    @Test func theFirstOpeningOfAWeekShowsTheRecapOnceAndNotAgain() async {
        let rig = CardRig()
        #expect(!rig.card.isShowing)
        await rig.open(on: 19)
        #expect(rig.card.isShowing && rig.card.recap?.sessions == 3)
        #expect(rig.scratch.defaults.string(forKey: RecapCard.seenKey) == RecapCard.weekKey(now: date(19), calendar: seoul))
        // Closing it, or the notch closing, and opening again the same week shows nothing and reads nothing.
        rig.card.close()
        await rig.open(on: 19)
        await rig.open(on: 22)
        #expect(!rig.card.isShowing)
        #expect(rig.reads.count == 1)
    }

    @Test func aLaterOpeningInTheWeekShowsItIfMondayWasMissed() async {
        let rig = CardRig()
        await rig.open(on: 23)
        #expect(rig.card.isShowing)
    }

    @Test func eachNewWeekShowsItAgain() async {
        let rig = CardRig()
        await rig.open(on: 19)
        rig.card.close()
        await rig.open(on: 26)
        #expect(rig.card.isShowing)
        #expect(rig.reads.count == 2)
    }

    @Test func aWeekIsNotReadTwiceWhileOneReadIsUnderway() async {
        let rig = CardRig()
        rig.card.notchOpened(enabled: true, canShow: { true }, now: date(19))
        rig.card.notchOpened(enabled: true, canShow: { true }, now: date(19))
        #expect(rig.card.isReading)
        await rig.settle()
        #expect(rig.reads.count == 1 && rig.card.isShowing)
    }

    @Test func withTheSettingOffItNeverShowsByItselfButTheButtonStillWorks() async {
        let rig = CardRig()
        await rig.open(on: 19, enabled: false)
        #expect(!rig.card.isShowing && !rig.card.isReading && rig.reads.count == 0)
        #expect(rig.scratch.defaults.string(forKey: RecapCard.seenKey) == nil)
        rig.card.show(now: date(19))
        #expect(rig.card.isShowing)
        await rig.settle()
        #expect(rig.card.recap?.sessions == 3)
    }

    @Test func anEmptyWeekIsNotShownAndNotLookedAtAgain() async {
        let rig = CardRig(result: recap(sessions: 0))
        await rig.open(on: 19)
        #expect(!rig.card.isShowing)
        await rig.open(on: 21)
        #expect(rig.reads.count == 1)
        // The button shows it all the same, as an empty week.
        rig.card.show(now: date(21))
        #expect(rig.card.isShowing && rig.card.recap?.isEmpty == true)
    }

    @Test func aRecapThatCannotShowYetWaitsForTheNextOpeningWithoutBeingReadAgain() async {
        let rig = CardRig()
        // A tour or a permission prompt has the notch when the read ends.
        await rig.open(on: 19, canShow: { false })
        #expect(!rig.card.isShowing)
        #expect(rig.scratch.defaults.string(forKey: RecapCard.seenKey) == nil)
        await rig.open(on: 20)
        #expect(rig.card.isShowing)
        #expect(rig.reads.count == 1)
    }

    @Test func theButtonShowsAndTheNotchClosingHidesIt() async {
        let rig = CardRig()
        rig.card.show(now: date(21))
        #expect(rig.card.isShowing && rig.card.isReading && rig.card.recap == nil)
        await rig.settle()
        #expect(rig.card.recap != nil)
        rig.card.close()
        #expect(!rig.card.isShowing)
        // Shown by the button counts as shown: the next opening of the week doesn't show it again.
        await rig.open(on: 22)
        #expect(!rig.card.isShowing && rig.reads.count == 1)
        // Last week's logs don't change, so showing it again doesn't read them again.
        rig.card.show(now: date(22))
        #expect(rig.card.isShowing && rig.card.recap != nil && rig.reads.count == 1)
    }

    @Test func savingWritesTheImageToDownloadsAndRevealsItWithoutOverwriting() async throws {
        let rig = CardRig()
        rig.card.show(now: date(21))
        await rig.settle()
        rig.card.saveImage(now: date(21))
        rig.card.saveImage(now: date(21))
        let first = rig.downloads.appendingPathComponent("Nunsseop recap 2026-10-21.png")
        let second = rig.downloads.appendingPathComponent("Nunsseop recap 2026-10-21 2.png")
        #expect(rig.revealed == [first, second])
        #expect(rig.card.saved == .saved(second))
        for file in [first, second] {
            let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
            #expect(image.pixelsWide == 1080 && image.pixelsHigh == 1920)
        }
    }

    @Test func aFolderThatCannotBeWrittenIsAFailureTheButtonSays() async {
        let rig = CardRig()
        rig.card.show(now: date(21))
        await rig.settle()
        try? FileManager.default.removeItem(at: rig.downloads)
        rig.card.saveImage(now: date(21))
        #expect(rig.card.saved == .failed && rig.revealed.isEmpty)
        rig.card.close()
        #expect(rig.card.saved == nil)
    }

    @Test func nothingIsSavedForAnEmptyWeek() async {
        let rig = CardRig(result: recap(sessions: 0))
        rig.card.show(now: date(21))
        await rig.settle()
        rig.card.saveImage(now: date(21))
        #expect(rig.card.saved == nil && rig.revealed.isEmpty)
    }

    @Test func theImageNameTakesANumberWhenTheNameIsTaken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-recap-names-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = try (0..<3).map { _ in try RecapImage.write(Data([1]), to: folder, now: date(5), calendar: seoul).lastPathComponent }
        #expect(names == ["Nunsseop recap 2026-10-05.png", "Nunsseop recap 2026-10-05 2.png", "Nunsseop recap 2026-10-05 3.png"])
        // What was there is left alone.
        try Data([9]).write(to: folder.appendingPathComponent("Nunsseop recap 2026-10-06.png"))
        _ = try RecapImage.write(Data([1]), to: folder, now: date(6), calendar: seoul)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Nunsseop recap 2026-10-06.png")) == Data([9]))
    }
}

// MARK: - Words

struct RecapWordsTests {
    private static let languages = ["de", "es", "fr", "ja", "ko", "zh-Hans"]
    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    /// Every sentence the recap says, as written in the source, with how many values it takes.
    private static let keys: [(String, Int)] = [
        ("What your brow saw last week", 0), ("Agent working time", 0), ("Sessions", 0), ("Lines changed", 0), ("Tokens", 0),
        ("Most worked project", 0), ("Longest session", 0), ("Busiest day: %@", 1), ("Busiest day", 0),
        ("↑ %@ vs the week before", 1), ("↓ %@ vs the week before", 1), ("Same as the week before", 0),
        ("Nothing the week before", 0), ("1 file", 0), ("%@ of the time", 1), ("%@ morning", 1), ("%@ afternoon", 1), ("%@ evening", 1),
        ("%@ night", 1), ("1 project", 0), ("%lld projects", 1), ("Names hidden", 0), ("Save image", 0), ("Saved to Downloads", 0),
        ("Couldn't save the image", 0), ("A quiet week", 0),
        ("No Claude Code or Codex sessions last week, so there is nothing to look back on.", 0), ("Last week", 0),
        ("Recap last week's agent work on Mondays", 0),
        ("Added up on this Mac from your coding agents' session files, and never sent anywhere. The AI tab can show it any time.", 0),
    ]

    /// Words that are the same in English and in the language.
    private static let sameInEnglish: Set<String> = ["de Tokens", "es Tokens", "fr Sessions"]

    private func table(_ language: String) throws -> [String: String] {
        let path = Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings").path
        return try #require(NSDictionary(contentsOfFile: path) as? [String: String], Comment(rawValue: language))
    }

    /// The sentence in a language with its one value put in.
    private func said(_ key: String, in table: [String: String], _ value: String = "") -> String {
        (table[key] ?? key).replacingOccurrences(of: "%@", with: value).replacingOccurrences(of: "%1$@", with: value)
            .replacingOccurrences(of: "%lld", with: value)
    }

    private func width(_ text: String, _ size: CGFloat, weight: NSFont.Weight = .regular, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    @Test func everySentenceIsTranslatedIntoEveryLanguageWithItsValues() throws {
        for language in Self.languages {
            let table = try table(language)
            for (key, values) in Self.keys {
                let text = table[key] ?? ""
                #expect(!text.isEmpty && (text != key || Self.sameInEnglish.contains("\(language) \(key)")), Comment(rawValue: "\(language): \(key)"))
                #expect(text.components(separatedBy: "%@").count - 1 + text.components(separatedBy: "%lld").count - 1 == values,
                        Comment(rawValue: "\(language): \(key)"))
            }
        }
    }

    @Test func theKoreanTitleIsTheOneTheOwnerChose() throws {
        #expect(try table("ko")["What your brow saw last week"] == "지난주, 눈썹이 지켜본 것")
    }

    @Test func theTitleLeavesRoomForTheDateAndBothButtons() throws {
        // The header is 596 points wide: two buttons take about 200 and the dates 80.
        for language in Self.languages {
            let title = try said("What your brow saw last week", in: table(language))
            #expect(width(title, 14, weight: .semibold) <= 300, Comment(rawValue: "\(language): \(title)"))
        }
    }

    /// A tile of the first row is 144 points wide less 16 of padding, and one of the second row 194 less 16.
    private static let small: CGFloat = 128, large: CGFloat = 178

    @Test func theLabelsFitTheirTiles() throws {
        for language in Self.languages {
            let table = try table(language)
            let weekdays = DateFormatter()
            weekdays.locale = Locale(identifier: language)
            let longest = (weekdays.weekdaySymbols ?? []).max { width($0, 10) < width($1, 10) } ?? ""
            for key in ["Agent working time", "Sessions", "Lines changed", "Tokens"] {
                let text = said(key, in: table)
                #expect(width(text, 10) <= Self.small, Comment(rawValue: "\(language): \(text) \(width(text, 10))"))
            }
            for text in ["Most worked project", "Longest session"].map({ said($0, in: table) }) + [said("Busiest day: %@", in: table, longest)] {
                #expect(width(text, 10) <= Self.large, Comment(rawValue: "\(language): \(text) \(width(text, 10))"))
            }
        }
    }

    @Test func theLinesUnderTheValuesFitTheirTiles() throws {
        for language in Self.languages {
            let table = try table(language)
            let hours = said("%lldh", in: table, "3"), minutes = said("%lldm", in: table, "20")
            let span = "\(hours) \(minutes)"
            let subs = [said("↑ %@ vs the week before", in: table, span), said("↓ %@ vs the week before", in: table, span),
                        said("Same as the week before", in: table), said("Nothing the week before", in: table),
                        said("%lld files", in: table, "1,234"), said("1 file", in: table)]
            for text in subs {
                // Lines of the first row may shrink by 15 % (`RecapTile`), so a line fits when it does at that size.
                #expect(width(text, 10) * 0.85 <= Self.small, Comment(rawValue: "\(language): \(text) \(width(text, 10))"))
            }
            let share = said("%@ of the time", in: table, "58%")
            #expect(width(share, 10) <= Self.large, Comment(rawValue: "\(language): \(share)"))
            let weekdays = DateFormatter()
            weekdays.locale = Locale(identifier: language)
            let longestDay = (weekdays.weekdaySymbols ?? []).max { width($0, 10) < width($1, 10) } ?? ""
            for key in ["%@ morning", "%@ afternoon", "%@ evening", "%@ night"] {
                // The day part, then a session name of about ten characters.
                let text = said(key, in: table, longestDay) + " \u{00B7} Login refactor"
                #expect(width(text, 10) * 0.85 <= Self.large, Comment(rawValue: "\(language): \(text) \(width(text, 10))"))
            }
        }
    }

    @Test func theValuesFitTheirTilesWithoutShrinkingMuchAndTheNumbersAreOnlyDigits() throws {
        for language in Self.languages {
            let table = try table(language)
            let span = "\(said("%lldh", in: table, "21")) \(said("%lldm", in: table, "40"))"
            // A tile's value shrinks by 40 % at most (`RecapTile`); a duration should need much less than that.
            #expect(width(span, 17, weight: .semibold, digits: true) <= Self.small / 0.75, Comment(rawValue: "\(language): \(span) \(width(span, 17, weight: .semibold, digits: true))"))
        }
        let lines = "+12,345 \u{2212}10,100"
        #expect(width(lines, 17, weight: .semibold, digits: true) <= Self.small / 0.75, Comment(rawValue: "\(width(lines, 17, weight: .semibold, digits: true))"))
    }

    @Test func theSubLinesWithToolNamesFit() {
        // Three digits for each tool is the most a week of sessions gets to in practice.
        let text = "Claude 312 \u{00B7} Codex 156"
        #expect(width(text, 10) * 0.85 <= Self.small, Comment(rawValue: "\(width(text, 10))"))
        // With more tools, the shortest line the tile falls back to: the most used tool and the others together.
        for language in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let others = language == "en" ? "Others" : (try? table(language))?["Others"] ?? ""
            let folded = "OpenCode 312 \u{00B7} \(others) 156"
            #expect(!others.isEmpty && width(folded, 10) * 0.85 <= Self.small, Comment(rawValue: "\(language): \(width(folded, 10))"))
        }
        let tokens = "Claude 123.4M \u{00B7} Codex 56.7M"
        #expect(width(tokens, 10) * 0.85 <= Self.small, Comment(rawValue: "\(width(tokens, 10))"))
    }
}
