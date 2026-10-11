import AppKit
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
         String(repeating: "e\u{301}", count: 200)]
    }

    private func prompt(_ detail: String, grant: PermissionPrompt.Grant? = nil, flags: [PermissionPrompt.Flag] = [],
                        secondary: String = "") -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, flags: flags, secondary: secondary,
                         folder: "proj", grant: grant)
    }

    // MARK: The measure is what is drawn

    @Test func theMeasuredHeightIsWhatTheViewDrawsAtTheNarrowestCardAndPanel() {
        for place in [PermissionLayout.Place.card, .panel] {
            for text in samples {
                let measured = PermissionLayout.height(text, font: PermissionLayout.codeFont, width: place.scrollWidth)
                let real = drawn(text, width: place.scrollWidth)
                #expect(abs(measured - real) <= 1, "\(place), \(text.prefix(20))…: drawn \(real), measured \(measured)")
            }
        }
    }

    @Test func longTokensTakeTheRowsTheViewReallyNeeds() {
        // A token too long to share a row with the next one wraps to a row of its own, which no character count sees.
        let rows = { (text: String) in PermissionLayout.rows(PermissionLayout.height(text, font: PermissionLayout.codeFont,
                                                                                    width: PermissionLayout.Place.card.scrollWidth)) }
        #expect(rows(sixTokens) == 6)
        #expect(rows(threeWords) == 3)
        #expect(rows(longRule) == 4)
        #expect(abs(drawn(sixTokens, width: PermissionLayout.Place.card.scrollWidth) - 6 * PermissionLayout.rowHeight) <= 1)
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
                                                 .init(rules: ["Bash(" + token(29) + " " + token(29) + " " + token(29) + ")"], place: .session)]
        let flags = [PermissionPrompt.Flag(text: "Sandbox off", warns: true), PermissionPrompt.Flag(text: "Runs in the background", warns: false)]
        for grant in grants {
            for detail in ["", "ls", "a\nb\nc\nd", String(repeating: "line of text\n", count: 30), token(900), sixTokens, threeWords] {
                for hasNotch in [true, false] {
                    let prompt = prompt(detail, grant: grant, flags: detail.isEmpty ? [] : flags, secondary: detail.isEmpty ? "" : "why: tests")
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
                            secondary: "description: y")
        let styled = PermissionDetail(prompt: prompt, visible: 40, planned: 40).styled
        #expect(String(styled.characters) == prompt.scrollText)
        var colours: [String: Color?] = [:]
        for run in styled.runs { colours[String(styled[run.range].characters)] = run.foregroundColor }
        #expect(colours["Sandbox off"] == .some(.orange))
        #expect(colours["Runs in the background"] != .some(.orange) && colours["curl x"] != .some(.orange))
        #expect(colours["description: y"] != nil)
    }
}
