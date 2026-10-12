import AppKit
import CoreText
import SwiftUI
import Testing
import Vision
@testable import Nunsseop

/// The closed notch is sized from measured text before anything is drawn, so the measure has to hold against the drawn text.
@MainActor
struct PermissionLayoutTests {
    private func fitting<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingView(rootView: view.frame(width: width)).fittingSize
    }

    private func drawn(_ text: String, width: CGFloat) -> CGFloat {
        fitting(Text(verbatim: text).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true),
                width: width).height
    }

    private func token(_ length: Int) -> String { String(repeating: "x", count: length) }

    private var sixTokens: String { Array(repeating: token(26), count: 6).joined(separator: " ") }
    private var threeWords: String { Array(repeating: token(25), count: 3).joined(separator: " ") }
    /// 125 characters in four words of 29: one word to a row of the card.
    private var longRule: String { "Bash(" + Array(repeating: token(29), count: 4).joined(separator: " ") + ")" }

    private var samples: [String] {
        ["ls", "git status && git diff --stat | head -50", token(47), token(48), token(49), String(repeating: "word ", count: 60),
         String(repeating: "W", count: 300), String(repeating: "한글", count: 40), String(repeating: "日本語のコマンド", count: 20),
         String(repeating: "😀", count: 80), "a\n\nb\n" + String(repeating: "c", count: 100) + "\nd",
         String(repeating: "/very/long/path/segment", count: 12), String(repeating: "⟨U+200B⟩", count: 30),
         "    indented\n        more indented\n\tsh", sixTokens, threeWords, longRule, "a\n", "a\n\n\n", "\n\n\n", "x\n\n y", " \n \n ",
         String(repeating: "e\u{301}", count: 200), rtl, "⇥ tabbed ⇥ ⇥ text", "⚠️ ❤️ 👨‍👩‍👧 done", "אבגד " + String(repeating: "שלום עולם ", count: 30),
         "مرحبا " + String(repeating: "echo ", count: 40), "\(rtl)\n\(rtl)\n\n\(rtl)", arabicDetail, arabicRule,
         PermissionText.escape(chain(60), multiline: true), PermissionText.escape("rm -rf /home/אבג/דהו\n/tmp/مرحبا/١٢٣/456", multiline: true),
         chain(4) + " " + chain(5) + " ©⟨U+200D⟩® ❤\u{FE0F}\u{200D}🔥"]
    }

    private let rtl = "א echo safe ; ב rm -rf /tmp/x ג ls"
    /// `people` women joined by joiners, with a joiner after the last.
    private func chain(_ people: Int) -> String { String(repeating: "👩\u{200D}", count: people) }
    /// Arabic text that wraps in one row fewer when it is not isolated: in the width of the card's scrolling text, and of its rules.
    private let arabicDetail = "ا.ثبث1اثب1ثتب1ث1  .تاب1تب.ثبت1 11. .ثا  تا1.1اببا 1ثبثااا1ثبث  اات بثت1ت.ثثث11بت.تبتبتا "
    private let arabicRule = "1 1تثثب  ات اثاتث.1بباتاثا ب.ت1تثبثبتاا1.ت1ثث1ت1ثت1ب1بب1.1ا ببتب.ات.1.ثث 1تث "
    /// A tool name of 100 characters, as an MCP server would send one.
    private let longName = "mcp__enterprise_wikis__search_documents_by_title_and_return_every_matching_paragraph_and_all_authors"

    private func prompt(_ detail: String, grant: PermissionPrompt.Grant? = nil, flags: [PermissionPrompt.Flag] = [],
                        secondary: String = "", title: String = "Run a command") -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: title, symbol: "terminal", detail: detail, flags: flags, secondary: secondary,
                         folder: "proj", grant: grant)
    }

    // MARK: The measure is what is drawn

    @Test func theMeasuredHeightIsWhatTheViewDrawsAtTheNarrowestCardAndPanel() {
        for place in [PermissionLayout.Place.card, .panel] {
            for text in samples {
                let isolated = PermissionText.isolated(text)
                let measured = PermissionLayout.height(isolated, font: PermissionLayout.codeFont, width: place.scrollWidth)
                let real = drawn(isolated, width: place.scrollWidth)
                #expect(abs(measured - real) <= 1, "\(place), \(text.prefix(20))…: drawn \(real), measured \(measured)")
            }
        }
    }

    @Test func theMeasureIsOfTheIsolatedTextBecauseIsolatingChangesTheRowsOfSomeArabic() {
        func rows(_ text: String, width: CGFloat) -> Int {
            PermissionLayout.rows(PermissionLayout.height(text, font: PermissionLayout.codeFont, width: width))
        }
        let scroll = PermissionLayout.Place.card.scrollWidth, rule = PermissionLayout.Place.card.width
        #expect(rows(arabicDetail, width: scroll) == 2 && rows(PermissionText.isolated(arabicDetail), width: scroll) == 3)
        #expect(rows(arabicRule, width: rule) == 2 && rows(PermissionText.isolated(arabicRule), width: rule) == 3)
        let shown = prompt(arabicDetail, grant: .init(rules: [arabicRule], place: .session))
        #expect(PermissionLayout.rows(shown.measure(.card).scroll) == 3 && PermissionLayout.rows(shown.measure(.card).rules) == 3)
    }

    @Test func longTokensTakeTheRowsTheViewReallyNeeds() {
        // A token too long to share a row with the next one wraps to a row of its own, which no character count sees.
        let rows = { (text: String) in PermissionLayout.rows(PermissionLayout.height(PermissionText.isolated(text), font: PermissionLayout.codeFont,
                                                                                    width: PermissionLayout.Place.card.scrollWidth)) }
        #expect(rows(sixTokens) == 6)
        #expect(rows(threeWords) == 3)
        #expect(rows(longRule) == 4)
        #expect(abs(drawn(PermissionText.isolated(sixTokens), width: PermissionLayout.Place.card.scrollWidth) - 6 * PermissionLayout.rowHeight) <= 1)
    }

    // MARK: Nothing the prompt shows is hidden without saying so

    private func hidden(_ prompt: PermissionPrompt, _ place: PermissionLayout.Place) -> Int {
        PermissionLayout.hiddenRows(content: prompt.measure(place).scroll, visible: PermissionLayout.visibleDetail(prompt, place))
    }

    @Test func whatTheDetailAreaLeavesOutIsAlwaysSaidAndCounted() {
        let rule = PermissionPrompt.Grant(rules: ["Bash(ls:*)"], place: .session)
        for place in [PermissionLayout.Place.card, .panel] {
            for text in samples where !text.isEmpty {
                for grant in [nil, rule] {
                    let prompt = prompt(text, grant: grant)
                    let visible = PermissionLayout.visibleDetail(prompt, place)
                    let hidden = hidden(prompt, place)
                    // Either all of it shows, or the note counts the rows that don't.
                    #expect(visible + CGFloat(hidden) * PermissionLayout.rowHeight >= prompt.measure(place).scroll - 0.5,
                            "\(place), \(grant == nil ? "no" : "a") rule, \(text.prefix(20))…")
                    #expect(hidden == 0 || visible < prompt.measure(place).scroll)
                }
            }
        }
    }

    @Test func sixLongTokensNeedAllSixRowsAndOneIsHiddenOnceARuleTakesARow() {
        let rule = PermissionPrompt.Grant(rules: ["Bash(ls:*)"], place: .session)
        let alone = prompt(sixTokens), withRule = prompt(sixTokens, grant: rule)
        #expect(PermissionLayout.rows(PermissionLayout.visibleDetail(alone, .card)) == 6 && hidden(alone, .card) == 0)
        #expect(PermissionLayout.rows(PermissionLayout.visibleDetail(withRule, .card)) == 5 && hidden(withRule, .card) == 1)
        #expect(PermissionLayout.note(hidden: 1) == "Scroll for the rest: 1 more line")
    }

    @Test func threeLongWordsShowWholeNotThroughTwoRows() {
        let three = prompt(threeWords)
        #expect(PermissionLayout.rows(PermissionLayout.visibleDetail(three, .card)) == 3 && hidden(three, .card) == 0)
        // Wide enough for two of them on a row, the panel needs only two.
        #expect(PermissionLayout.rows(PermissionLayout.visibleDetail(three, .panel)) == 2)
    }

    @Test func theNoteCountsRowsEvenForTextThatLooksBlank() {
        let blank = prompt(String(repeating: "\n", count: 40))
        let rows = PermissionLayout.rows(blank.measure(.card).scroll)
        #expect(rows == 41)
        #expect(hidden(blank, .card) == rows - PermissionLayout.maxDetailRows)
        #expect(PermissionLayout.note(hidden: hidden(blank, .card)) == "Scroll for the rest: 35 more lines")
    }

    @Test func nothingIsHiddenWhenItAllFits() {
        #expect(PermissionLayout.hiddenRows(content: 3 * PermissionLayout.rowHeight, visible: 3 * PermissionLayout.rowHeight) == 0)
        #expect(PermissionLayout.hiddenRows(content: 0, visible: 0) == 0)
        #expect(PermissionLayout.hiddenRows(content: 7 * PermissionLayout.rowHeight, visible: 6 * PermissionLayout.rowHeight) == 1)
    }

    // MARK: The rules and the line under them

    @Test func aRuleThatTakesMoreThanThreeRowsIsNotOfferedAndLeavesNoGap() {
        let long = PermissionPrompt.Grant(rules: [longRule], place: .localSettings)
        #expect(longRule.count == 125)
        #expect(!PermissionLayout.offers(long, place: .card))
        for place in [PermissionLayout.Place.card, .panel] where !PermissionLayout.offers(long, place: place) {
            let with = prompt("ls", grant: long)
            #expect(PermissionLayout.offered(with, place) == nil)
            #expect(PermissionLayout.height(of: with, showsTitle: true, stacked: true, place: place)
                    == PermissionLayout.height(of: prompt("ls"), showsTitle: true, stacked: true, place: place))
        }
        let fits = PermissionPrompt.Grant(rules: ["Bash(" + token(29) + " " + token(29) + ")"], place: .localSettings)
        #expect(PermissionLayout.offers(fits, place: .card))
    }

    @Test func threeWordsOfARuleFitAndTheRuleListNeverOverlapsTheCaption() {
        let gate = PermissionClickGate()
        let rules = [["Bash(" + token(29) + " " + token(29) + " " + token(29) + ")"], ["Bash(a:*)", "Read(/a/**)", "WebFetch"], [token(40)]]
        for list in rules {
            let grant = PermissionPrompt.Grant(rules: list, place: .userSettings)
            let prompt = prompt("ls", grant: grant)
            #expect(PermissionLayout.offered(prompt, .card) != nil, "\(list)")
            // The body is as tall as the rows and the line are laid out one under the other, so the line can't be drawn over the rules.
            let view = PermissionBody(prompt: prompt, showsTitle: false, stacked: true, place: .card, gate: gate) { _ in }
            let height = fitting(view, width: PermissionLayout.Place.card.width).height
            let sized = PermissionLayout.height(of: prompt, showsTitle: false, stacked: true, place: .card) - PermissionLayout.bottomPad
            #expect(abs(height - sized) <= 1, "\(list): drawn \(height), sized \(sized)")
            let m = prompt.measure(.card)
            #expect(m.rules >= CGFloat(list.count) * PermissionLayout.rowHeight - 1 && m.caption > 0)
        }
    }

    // MARK: The notch is as tall as the card

    @Test func thePanelIsAsTallAsTheOpenNotchWasSizedFor() {
        let gate = PermissionClickGate()
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(npm run *)"], place: .session),
                                                 .init(rules: ["Bash(git status:*)", "Read(/a/**)", "WebFetch"], place: .userSettings)]
        for grant in grants {
            for detail in ["", "ls", String(repeating: "line of text\n", count: 30), token(900), sixTokens, threeWords] {
                let prompt = prompt(detail, grant: grant)
                let view = PermissionPanel(prompt: prompt, count: 1, gate: gate) { _ in }
                let height = fitting(view, width: PermissionLayout.Place.panel.width).height
                #expect(abs(height - PermissionPanel.height(for: prompt)) <= 1,
                        "\(grant?.rules.count ?? 0) rules, \(detail.count) characters: drawn \(height), sized \(PermissionPanel.height(for: prompt))")
            }
        }
    }

    @Test func theBodyIsAsTallAsTheClosedNotchWasSizedFor() {
        let gate = PermissionClickGate()
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(npm run *)"], place: .localSettings),
                                                 .init(rules: ["Bash(git status:*)", "Read(/a/**)", "WebFetch"], place: .userSettings),
                                                 .init(rules: ["Bash(" + token(29) + " " + token(29) + " " + token(29) + ")"], place: .session),
                                                 .init(rules: [arabicRule], place: .session)]
        let flags = [PermissionPrompt.Flag(text: "Sandbox off", warns: true), PermissionPrompt.Flag(text: "Runs in the background", warns: false)]
        for grant in grants {
            for detail in ["", "ls", "a\nb\nc\nd", String(repeating: "line of text\n", count: 30), token(900), sixTokens, threeWords, rtl,
                           "\(rtl)\n\n\(rtl)\n", "⇥ ⇥ ⚠️ 👨‍👩‍👧", arabicDetail] {
                for hasNotch in [true, false] {
                    let prompt = prompt(detail, grant: grant, flags: detail.isEmpty ? [] : flags, secondary: detail.isEmpty ? "" : "why: tests",
                                        title: detail == rtl ? longName : "Run a command")
                    let view = PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, place: .card, gate: gate) { _ in }
                        .padding(.horizontal, 6)
                    // The room under the buttons is the shape's, not the body's.
                    let height = fitting(view, width: PermissionLayout.Place.card.width + 12).height + PermissionLayout.bottomPad
                    let sized = PermissionCard.bodyHeight(for: prompt, hasNotch: hasNotch)
                    #expect(abs(height - sized) <= 1, "\(grant?.rules.count ?? 0) rules, \(detail.count) characters, notch \(hasNotch): drawn \(height), sized \(sized)")
                }
            }
        }
    }

    // MARK: The name

    /// What a line of drawn text reads as, by recognizing the pixels it was drawn in.
    private func reading<V: View>(_ view: V, width: CGFloat, height: CGFloat = 24) throws -> String {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading).background(Color.black)
            .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try recognized(bitmap)
    }

    private func recognized(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Small type reads poorly at one pixel per point, so the pixels are enlarged first.
        let source = try #require(bitmap.cgImage)
        let scale = 4
        let context = try #require(CGContext(data: nil, width: source.width * scale, height: source.height * scale, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width * scale, height: source.height * scale))
        try VNImageRequestHandler(cgImage: try #require(context.makeImage())).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func letters(_ text: String) -> String { text.lowercased().filter(\.isLetter) }

    @Test func aToolNameTooLongForTheLineShowsItsEndNotJustItsStart() throws {
        let name = "mcp__server__someRatherLongToolNameThatEndsWithTheLastWord"
        let prompt = PermissionPrompt(id: UUID(), title: name, symbol: "terminal", detail: "", folder: "proj", grant: nil)
        let shown = try reading(PermissionTitle(prompt: prompt), width: 240)
        #expect(letters(shown).contains("lastword") && letters(shown).hasPrefix("mcp"), "read \(shown)")
        // The same reading of a name cut at its tail does not find the end, so the check can tell the two apart.
        let tail = try reading(Text(verbatim: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            .truncationMode(.tail), width: 240)
        #expect(!letters(tail).contains("lastword") && letters(tail).hasPrefix("mcp"), "read \(tail)")
    }

    // MARK: The note

    // MARK: Right-to-left letters

    /// The view drawn four pixels to the point, white on black, for reading ink off.
    private func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, direction: LayoutDirection = .leftToRight) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.environment(\.layoutDirection, direction)
            .frame(width: width, height: height, alignment: .topLeading).background(Color.black).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 4, pixelsHigh: Int(height) * 4, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Where the ink is from left to right: runs of columns that have some, as x ranges in points, told apart by gaps wider than `gap`.
    private func inkRuns(_ bitmap: NSBitmapImageRep, gap: CGFloat = 3.5) throws -> [ClosedRange<CGFloat>] {
        let image = try #require(bitmap.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / bitmap.size.width
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?, last = 0
        for x in 0..<width where (0..<height).contains(where: { pixels[($0 * width + x) * 4 + 1] > 90 }) {
            if let first = start, CGFloat(x - last) > gap * scale {
                runs.append(CGFloat(first) / scale...CGFloat(last + 1) / scale)
                start = x
            } else if start == nil {
                start = x
            }
            last = x
        }
        if let first = start { runs.append(CGFloat(first) / scale...CGFloat(last + 1) / scale) }
        return runs
    }

    /// The width in letters of every run wider than a Hebrew letter: for the sample, "echo safe ; ב rm -rf /tmp/x ג ls" is
    /// 4 4 2 3 6 2 left to right, and 2 2 3 6 4 4 once the clauses are turned around.
    private func clauses(_ runs: [ClosedRange<CGFloat>]) -> [Int] {
        let cell = PermissionLayout.codeFont.maximumAdvancement.width
        return runs.map { Int((($0.upperBound - $0.lowerBound) / cell).rounded()) }.filter { $0 >= 2 }
    }

    private let inOrder = [4, 4, 2, 3, 6, 2]
    private let turnedAround = [2, 2, 3, 6, 4, 4]

    @Test func rightToLeftLettersDoNotReorderTheClausesOfTheDetailTheRulesOrTheTitle() throws {
        // Without the isolates the same text, drawn the same way, is turned around; that is what the check tells apart.
        let plain = try snapshot(Text(verbatim: rtl).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white), width: 332, height: 20)
        #expect(clauses(try inkRuns(plain)) == turnedAround)

        let shown = prompt(rtl)
        let detail = try snapshot(PermissionDetail(prompt: shown, visible: 40, planned: 40), width: 332, height: 40)
        #expect(clauses(try inkRuns(detail)) == inOrder)

        let withRule = prompt("", grant: .init(rules: [rtl], place: .session))
        let rule = try snapshot(PermissionBody(prompt: withRule, showsTitle: false, stacked: true, place: .card, gate: PermissionClickGate()) { _ in }
            .frame(height: PermissionLayout.rowHeight, alignment: .top).clipped(), width: 332, height: 40)
        #expect(clauses(try inkRuns(rule)) == inOrder)

        // The title is not monospaced, so its three words are told apart by length: 10, 5 and 3 letters, longest first.
        let words = "א mmmmmmmmmm ב mmmmm ג mmm"
        func widths(title: String, folder: String) throws -> [CGFloat] {
            let titled = PermissionPrompt(id: UUID(), title: title, symbol: "terminal", detail: "", folder: folder, grant: nil)
            let runs = try inkRuns(try snapshot(PermissionTitle(prompt: titled), width: 332, height: 20))
            return runs.map { $0.upperBound - $0.lowerBound }.filter { $0 > 15 }
        }
        for (title, folder) in [(words, ""), ("x", words)] {
            let widths = try widths(title: title, folder: folder)
            #expect(widths.count == 3 && widths == widths.sorted(by: >), "\(title.prefix(3)) \(widths)")
        }
    }

    @Test func whatIsDrawnDoesNotChangeWhenTheSystemReadsRightToLeft() throws {
        let rule = PermissionPrompt.Grant(rules: ["Bash(ls:*)"], place: .session)
        let shown = prompt(rtl + "\nsecond line", grant: rule, flags: [.init(text: "Sandbox off", warns: true)], secondary: "description: x", title: longName)
        let gate = PermissionClickGate()
        func png(_ view: some View, width: CGFloat, direction: LayoutDirection) throws -> Data {
            try #require(try snapshot(view, width: width, height: 260, direction: direction).representation(using: .png, properties: [:]))
        }
        for hasNotch in [true, false] {
            let card = PermissionCard(prompt: shown, count: 2, height: 32, earWidth: 102, hasNotch: hasNotch, gate: gate) { _ in }
            #expect(try png(card, width: 380, direction: .rightToLeft) == png(card, width: 380, direction: .leftToRight), "card, notch \(hasNotch)")
        }
        let panel = PermissionPanel(prompt: shown, count: 2, gate: gate) { _ in }
        #expect(try png(panel, width: 476, direction: .rightToLeft) == png(panel, width: 476, direction: .leftToRight))
        // A view that doesn't hold its direction does change, so the check can tell.
        let loose = PermissionBody(prompt: shown, showsTitle: true, stacked: true, place: .card, gate: gate) { _ in }
        #expect(try png(loose, width: 332, direction: .rightToLeft) != png(loose, width: 332, direction: .leftToRight))
    }

    // MARK: Honest order

    /// Whether any run of glyphs `text` is drawn in goes right to left, as CoreText, which draws the card's text, lays it out.
    private func runsRightToLeft(_ text: String) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: PermissionLayout.codeFont]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).contains { CTRunGetStatus($0).contains(.rightToLeft) }
    }

    @Test func nothingOfTheDetailIsDrawnRightToLeftSoItsOrderIsTheOrderItWasWritten() throws {
        let commands = ["rm -rf /home/אבג/דהו", "ls /tmp/مرحبا/١٢٣/456", "echo א 1 ; ב 2", rtl, arabicDetail]
        for command in commands {
            // Raw, with the isolates the card used to rely on alone, the letters still run right to left among themselves.
            #expect(runsRightToLeft(PermissionText.isolated(command)), "\(command)")
            let shown = try #require(PermissionPrompt.parse(PermissionTestServer.hookInput(tool: "Bash", input: ["command": command]))).prompt
            #expect(!runsRightToLeft(PermissionText.isolated(shown.detail)), "\(command)")
            let drawn = PermissionDetail(prompt: shown, visible: 40, planned: 40)
            #expect(!runsRightToLeft(String(drawn.styled.characters)), "\(command)")
        }
        // The same for a rule, the title and the folder.
        let hook = PermissionTestServer.hookInput(tool: "mcp__שרת__ملف", input: [:], cwd: "/Users/me/תיקייה",
                                                  suggestions: [["type": "addRules", "behavior": "allow", "destination": "session",
                                                                 "rules": [["toolName": "Bash", "ruleContent": "echo א 1 ; ב 2"]]]])
        let shown = try #require(PermissionPrompt.parse(hook))
        #expect(shown.prompt.grant == nil && shown.suggestion == nil)
        for part in [shown.prompt.title, shown.prompt.folder, shown.prompt.toolLine, shown.prompt.scrollText] {
            #expect(!runsRightToLeft(PermissionText.isolated(part)), "\(part)")
        }
    }

    @Test func aLongChainOfJoinersWrapsInRowsThatAreCountedAndSaidNotClipped() throws {
        func prompt(_ people: Int) throws -> PermissionPrompt {
            try #require(PermissionPrompt.parse(PermissionTestServer.hookInput(tool: "Bash", input: ["command": chain(people)]))).prompt
        }
        for people in [60, 300] {
            let long = try prompt(people)
            for place in [PermissionLayout.Place.card, .panel] {
                let measured = PermissionLayout.height(PermissionText.isolated(long.detail), font: PermissionLayout.codeFont, width: place.scrollWidth)
                let real = drawn(PermissionText.isolated(long.detail), width: place.scrollWidth)
                #expect(abs(measured - real) <= 1, "\(people) women, \(place): drawn \(real), measured \(measured)")
                // Several rows, not one that is wider than the card.
                #expect(PermissionLayout.rows(real) > 1)
            }
        }
        // 300 women are more rows than show: the note says how many more, as many as the drawn text has.
        let long = try prompt(300)
        let shown = PermissionLayout.visibleDetail(long, .card)
        let rows = PermissionLayout.rows(long.measure(.card).scroll)
        let say = PermissionLayout.hiddenRows(content: long.measure(.card).scroll, visible: shown)
        #expect(say > 0 && say == rows - PermissionLayout.rows(shown))
        let read = try reading(PermissionDetail(prompt: long, visible: shown, planned: long.measure(.card).scroll),
                               width: PermissionLayout.Place.card.width, height: 140)
        #expect(read.contains("\(say) more lines"), "read \(read), expected \(say)")
        // Sixty of them: the row count is what the view reports once drawn.
        let sixty = try prompt(60)
        let reported = try reading(PermissionDetail(prompt: sixty, visible: PermissionLayout.visibleDetail(sixty, .card), planned: sixty.measure(.card).scroll),
                                   width: PermissionLayout.Place.card.width, height: 140)
        let sixtyHidden = PermissionLayout.hiddenRows(content: sixty.measure(.card).scroll, visible: PermissionLayout.visibleDetail(sixty, .card))
        if sixtyHidden == 0 {
            #expect(!reported.contains("more line"), "read \(reported)")
        } else {
            #expect(reported.contains("\(sixtyHidden) more line"), "read \(reported), expected \(sixtyHidden)")
        }
        // Family and flame stay what they are.
        #expect(try #require(PermissionPrompt.parse(PermissionTestServer.hookInput(tool: "Bash", input: ["command": "👨\u{200D}👩\u{200D}👧 ❤\u{FE0F}\u{200D}🔥"]))).prompt.detail
                == "👨\u{200D}👩\u{200D}👧 ❤\u{FE0F}\u{200D}🔥")
    }

    // MARK: The title and the position label

    /// The closed card as the notch draws it on a display without a camera at the narrowest, 380 wide with 18 on each side.
    private func topRow(_ prompt: PermissionPrompt, count: Int) throws -> NSBitmapImageRep {
        let card = PermissionCard(prompt: prompt, count: count, height: 32, earWidth: 102, hasNotch: false, gate: PermissionClickGate()) { _ in }
            .padding(.horizontal, 18)
        return try snapshot(card, width: 380, height: 260)
    }

    /// The pixels of the top row of `bitmap` left of `x` points.
    private func leftOf(_ x: CGFloat, _ bitmap: NSBitmapImageRep) throws -> Data {
        let image = try #require(bitmap.cgImage)
        let scale = CGFloat(image.width) / bitmap.size.width
        let cut = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: x * scale, height: 32 * scale)))
        return try #require(NSBitmapImageRep(cgImage: cut).representation(using: .png, properties: [:]))
    }

    @Test func aTitleThatIsSaidToFitIsNotCutWhateverIsQueuedBehindIt() throws {
        // The label's room is made for 999 prompts, with at least 20 points to spare.
        let label = NSHostingView(rootView: Text("1 of 999").font(.system(size: 11, weight: .medium).monospacedDigit()).fixedSize()).fittingSize.width
        #expect(PermissionLayout.titleRoom <= PermissionLayout.topRowWidth - 20 - 3 * 8 - label - 20)
        for unit in ["m", "W", "i", "0", "한", "Mi"] {
            for folder in ["", "proj", "nunsseop-web-app"] {
                let longest = (1...200).last { PermissionLayout.titleFits(String(repeating: unit, count: $0), folder: folder) } ?? 0
                #expect(longest > 0, "\(unit)")
                let title = String(repeating: unit, count: longest)
                let fits = PermissionPrompt(id: UUID(), title: title, symbol: "terminal", detail: "", folder: folder, grant: nil)
                #expect(fits.toolLine.isEmpty)
                // The same prompt with nothing queued has all the room there is; with others queued its title looks no different.
                let alone = try leftOf(280, try topRow(fits, count: 1))
                for count in [2, 12, 100, 999] {
                    #expect(try leftOf(280, try topRow(fits, count: count)) == alone, "\(unit) x\(longest), folder \(folder), \(count) queued")
                }
                // One more and the tool's name is written out in the scrolling text.
                let more = PermissionPrompt(id: UUID(), title: title + unit, symbol: "terminal", detail: "", folder: folder, grant: nil)
                #expect(more.toolLine == "tool: " + title + unit)
            }
        }
    }

    @Test func aTitleTooLongForItsLineIsDrawnDifferentlyWhichIsWhatTheCheckAboveTellsApart() throws {
        // A name that does not fit is cut in the top row, and then the scrolling text has it whole; the cut shows in the pixels.
        let name = String(repeating: "m", count: 40)
        let cut = PermissionPrompt(id: UUID(), title: name, symbol: "terminal", detail: "", folder: "proj", grant: nil)
        #expect(cut.toolLine == "tool: " + name)
        #expect(try leftOf(280, try topRow(cut, count: 999)) != leftOf(280, try topRow(cut, count: 1)))
    }

    // MARK: A one-line edit

    private func edit(old: String = "let a = 1", new: String = "let a = 2", rule: Bool) throws -> PermissionPrompt {
        let suggestions: [[String: Any]]? = rule
            ? [["type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": [["toolName": "Edit", "ruleContent": "/a/b.swift"]]]]
            : nil
        let body = PermissionTestServer.hookInput(tool: "Edit", input: ["file_path": "/a/b.swift", "old_string": old, "new_string": new],
                                                  cwd: "/Users/me/proj", suggestions: suggestions)
        let prompt = try #require(PermissionPrompt.parse(body)).prompt
        #expect((prompt.grant != nil) == rule)
        return prompt
    }

    @Test func aOneLineEditFitsWithoutScrollingWithOrWithoutARuleToAdd() throws {
        for rule in [false, true] {
            let prompt = try edit(rule: rule)
            #expect(prompt.detail == "/a/b.swift\nold:\nlet a = 1\nnew:\nlet a = 2")
            for place in [PermissionLayout.Place.card, .panel] {
                #expect(hidden(prompt, place) == 0 && PermissionLayout.rows(prompt.measure(place).scroll) == 5, "\(place), rule \(rule)")
                #expect(PermissionLayout.rows(PermissionLayout.visibleDetail(prompt, place)) == 5, "\(place), rule \(rule)")
            }
            let gate = PermissionClickGate()
            let read = try reading(PermissionBody(prompt: prompt, showsTitle: false, stacked: true, place: .card, gate: gate) { _ in },
                                   width: PermissionLayout.Place.card.width, height: 200)
            #expect(read.contains("let a = 2") && !letters(read).contains("scrollfortherest"), "rule \(rule), read \(read)")
        }
        // What does overflow is still counted and said.
        let long = try edit(old: "a\nb\nc", new: "d\ne\nf\ng\nh", rule: true)
        #expect(hidden(long, .card) == PermissionLayout.rows(long.measure(.card).scroll) - 5 && hidden(long, .card) > 0)
    }

    // MARK: The tool's own name

    @Test func aLongToolNameIsReadableInFullInTheScrollingText() throws {
        #expect(longName.count == 100)
        let prompt = try #require(PermissionPrompt.parse(PermissionTestServer.hookInput(tool: longName, input: ["query": "x"]))).prompt
        #expect(prompt.title == longName && prompt.toolLine == "tool: " + longName)
        let rows = PermissionLayout.rows(prompt.measure(.card).scroll)
        // Its own rows, then the input.
        #expect(rows > PermissionLayout.rows(PermissionLayout.height("{\n  \"query\" : \"x\"\n}", font: PermissionLayout.codeFont,
                                                                      width: PermissionLayout.Place.card.scrollWidth)))
        let read = try reading(PermissionDetail(prompt: prompt, visible: PermissionLayout.visibleDetail(prompt, .card), planned: prompt.measure(.card).scroll),
                               width: PermissionLayout.Place.card.width, height: 120)
        #expect(letters(read).hasPrefix("tool") && letters(read).contains("enterprisewikis") && read.contains("more line"), "read \(read)")
        // The title still loses its middle, so the name is on the card twice and neither is cut at its end.
        let title = try reading(PermissionTitle(prompt: prompt), width: 240)
        #expect(letters(title).hasPrefix("mcp") && letters(title).contains("allauthors"), "read \(title)")
    }

    // MARK: A new prompt in front

    @Test func aPromptNeverStartsWithTheHeightTheOneBeforeItWasDrawnAt() throws {
        let one = UUID(), other = UUID()
        let drawn = PermissionDetail.Drawn(prompt: one, height: 126)
        #expect(PermissionDetail.contentHeight(planned: 14, drawn: drawn, prompt: one) == 126)
        #expect(PermissionDetail.contentHeight(planned: 14, drawn: drawn, prompt: other) == 14)
        #expect(PermissionDetail.contentHeight(planned: 14, drawn: nil, prompt: one) == 14)

        // Drawn: the card of nine lines is replaced by one of a line, and then the other way round.
        let gate = PermissionClickGate()
        let long = prompt((1...9).map { "line \($0)" }.joined(separator: "\n")), short = prompt("ls")
        func front(_ prompt: PermissionPrompt) -> some View {
            PermissionBody(prompt: prompt, showsTitle: false, stacked: true, place: .card, gate: gate) { _ in }
                .frame(width: PermissionLayout.Place.card.width, height: 200, alignment: .topLeading).background(Color.black)
                .environment(\.colorScheme, .dark)
        }
        func read(_ hosting: NSHostingView<some View>) throws -> String {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try recognized(bitmap)
        }
        let hosting = NSHostingView(rootView: AnyView(front(long)))
        hosting.frame = CGRect(x: 0, y: 0, width: PermissionLayout.Place.card.width, height: 200)
        #expect(try read(hosting).contains("3 more lines"))
        hosting.rootView = AnyView(front(short))
        #expect(!(try read(hosting)).contains("more line"))
        hosting.rootView = AnyView(front(long))
        #expect(try read(hosting).contains("3 more lines"))
    }

    @Test func theDrawnCardSaysHowManyRowsItLeavesOut() throws {
        func detail(_ text: String) -> PermissionDetail {
            let prompt = prompt(text)
            return PermissionDetail(prompt: prompt, visible: PermissionLayout.visibleDetail(prompt, .card), planned: prompt.measure(.card).scroll)
        }
        let nine = (1...9).map { "line \($0)" }.joined(separator: "\n")
        let note = try reading(detail(nine), width: PermissionLayout.Place.card.width, height: 120)
        #expect(letters(note).contains("scrollfortherest") && note.contains("3 more lines"), "read \(note)")
        let seven = try reading(detail((1...7).map { "line \($0)" }.joined(separator: "\n")), width: PermissionLayout.Place.card.width, height: 120)
        #expect(seven.contains("1 more line") && !seven.contains("more lines"), "read \(seven)")
        let six = try reading(detail((1...6).map { "line \($0)" }.joined(separator: "\n")), width: PermissionLayout.Place.card.width, height: 120)
        #expect(!letters(six).contains("scroll") && letters(six).contains("line"), "read \(six)")
        let blank = try reading(detail(String(repeating: "\n", count: 12)), width: PermissionLayout.Place.card.width, height: 120)
        #expect(blank.contains("7 more lines"), "read \(blank)")
    }

    @Test func theHeightTheTextReportsOnceDrawnReplacesTheMeasuredOne() throws {
        // A plan that is wrong, as one is for text the measure can't predict: the drawn text decides what is hidden.
        let nine = prompt((1...9).map { "line \($0)" }.joined(separator: "\n"))
        let wrong = try reading(PermissionDetail(prompt: nine, visible: 6 * PermissionLayout.rowHeight, planned: 2 * PermissionLayout.rowHeight),
                                width: PermissionLayout.Place.card.width, height: 120)
        #expect(wrong.contains("3 more lines"), "read \(wrong)")
    }

    @Test func theAlwaysAllowButtonIsDrawnOnlyWhenTheWholeRuleListFits() throws {
        let gate = PermissionClickGate()
        func body(_ rule: String) throws -> String {
            let prompt = prompt("ls", grant: .init(rules: [rule], place: .session))
            return try reading(PermissionBody(prompt: prompt, showsTitle: false, stacked: true, place: .card, gate: gate) { _ in },
                               width: PermissionLayout.Place.card.width, height: 200)
        }
        let fits = try body("Bash(" + token(29) + " " + token(29) + ")")
        #expect(letters(fits).contains("alwaysallow"), "read \(fits)")
        let tooLong = try body(longRule)
        #expect(!letters(tooLong).contains("alwaysallow") && letters(tooLong).contains("allow"), "read \(tooLong)")
    }

    @Test func theCaptionAndRuleRowsAreMeasuredAsDrawn() {
        let grant = PermissionPrompt.Grant(rules: ["Bash(a:*)"], place: .localSettings)
        for place in [PermissionLayout.Place.card, .panel] {
            for text in [grant.caption, "Always allow saves this " + String(repeating: "everywhere and then some ", count: 6)] {
                let measured = PermissionLayout.height(text, font: PermissionLayout.captionFont, width: place.width)
                let real = fitting(Text(verbatim: text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true), width: place.width).height
                #expect(abs(measured - real) <= 1, "\(place), \(text.prefix(30))…: drawn \(real), measured \(measured)")
            }
        }
    }

    @Test func theSandboxBeingOffIsDrawnInTheWarningColourAndTheRestIsNot() {
        let prompt = prompt("curl x", flags: [.init(text: "Sandbox off", warns: true), .init(text: "Runs in the background", warns: false)],
                            secondary: "description: y", title: longName)
        let styled = PermissionDetail(prompt: prompt, visible: 40, planned: 40).styled
        #expect(prompt.toolLine == "tool: " + longName)
        #expect(String(styled.characters) == PermissionText.isolated(prompt.scrollText))
        var colours: [String: Color?] = [:]
        for run in styled.runs { colours[String(styled[run.range].characters)] = run.foregroundColor }
        func colour(_ line: String) -> Color?? { colours[PermissionText.isolated(line)] }
        #expect(colour("Sandbox off") == .some(.orange))
        #expect(colour("Runs in the background") != .some(.orange) && colour("curl x") != .some(.orange))
        // The chip for letters that look like Latin is a warning like it.
        let chipped = PermissionDetail(prompt: self.prompt("curl x", flags: [.init(text: "Letters that look like Latin", warns: true)]), visible: 40, planned: 40).styled
        var chipColours: [String: Color?] = [:]
        for run in chipped.runs { chipColours[String(chipped[run.range].characters)] = run.foregroundColor }
        #expect(chipColours[PermissionText.isolated("Letters that look like Latin")] == .some(.some(.orange)))
        #expect(colour("tool: " + longName) != .some(.orange))
        // The description is quieter than the command, like every other field after it.
        #expect(colour("description: y") == .some(.white.opacity(0.6)) && colour("curl x") == .some(.white.opacity(0.85)))
    }

    // MARK: The chip for letters that look like Latin

    /// The sentence of every language the app is localized into, read from the files the app ships.
    private var chipTexts: [(language: String, text: String)] {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: resources.path))?.filter { $0.hasSuffix(".lproj") }.sorted() ?? []
        return folders.compactMap { folder in
            guard let table = NSDictionary(contentsOfFile: resources.appendingPathComponent(folder).appendingPathComponent("Localizable.strings").path),
                  table["Sandbox off"] != nil else { return nil }
            return (folder, table["Letters that look like Latin"] as? String ?? "")
        }
    }

    @Test func theChipIsTranslatedIntoEveryLanguageSandboxOffIs() {
        let texts = chipTexts
        #expect(Set(texts.map(\.language)) == ["de.lproj", "es.lproj", "fr.lproj", "ja.lproj", "ko.lproj", "zh-Hans.lproj"], "\(texts.map(\.language))")
        for (language, text) in texts {
            #expect(!text.isEmpty && text != "Letters that look like Latin", "\(language): \(text)")
        }
        #expect(texts.first { $0.language == "ko.lproj" }?.text == "라틴 문자와 닮은 글자")
    }

    /// In every language, the chip takes one row at the narrowest card and panel, and the body is as tall as it was sized for with the chip among the flags.
    @Test func theChipFitsTheMeasuredLayoutInEveryLanguage() {
        let gate = PermissionClickGate()
        let flags = { (text: String) in [PermissionPrompt.Flag(text: "Sandbox off", warns: true), .init(text: "Runs in the background", warns: false), .init(text: text, warns: true)] }
        for (language, text) in chipTexts + [("en", "Letters that look like Latin")] {
            for place in [PermissionLayout.Place.card, .panel] {
                let isolated = PermissionText.isolated(text)
                let measured = PermissionLayout.height(isolated, font: PermissionLayout.codeFont, width: place.scrollWidth)
                #expect(measured == PermissionLayout.rowHeight, "\(language) \(place): \(measured) for one row")
                #expect(abs(drawn(isolated, width: place.scrollWidth) - measured) <= 1, "\(language) \(place)")
            }
            for hasNotch in [true, false] {
                let prompt = prompt("curl \u{430}", flags: flags(text), secondary: "description: x")
                let view = PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, place: .card, gate: gate) { _ in }.padding(.horizontal, 6)
                let height = fitting(view, width: PermissionLayout.Place.card.width + 12).height + PermissionLayout.bottomPad
                let sized = PermissionCard.bodyHeight(for: prompt, hasNotch: hasNotch)
                #expect(abs(height - sized) <= 1, "\(language), notch \(hasNotch): drawn \(height), sized \(sized)")
            }
            let prompt = prompt("curl x", flags: flags(text))
            let panel = PermissionPanel(prompt: prompt, count: 1, gate: gate) { _ in }
            #expect(abs(fitting(panel, width: PermissionLayout.Place.panel.width).height - PermissionPanel.height(for: prompt)) <= 1, "\(language) panel")
        }
        // The chip makes the prompt taller by the row it takes, and nothing else.
        let plain = prompt("curl x"), chipped = prompt("curl x", flags: [.init(text: "Letters that look like Latin", warns: true)])
        #expect(chipped.card.scroll - plain.card.scroll == PermissionLayout.rowHeight && chipped.panel.scroll - plain.panel.scroll == PermissionLayout.rowHeight)
    }
}
