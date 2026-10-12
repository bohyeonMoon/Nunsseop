import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

/// The closed notch is sized from measured text before anything is drawn, so the measure of a question has to hold against what is drawn.
@MainActor
struct PermissionQuestionLayoutTests {
    private typealias Q = QuestionFixtures

    private func fitting<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingView(rootView: view.frame(width: width)).fittingSize
    }

    private func drawn(_ text: String, font: Font, width: CGFloat) -> CGFloat {
        fitting(Text(verbatim: text).font(font).fixedSize(horizontal: false, vertical: true), width: width).height
    }

    private let places: [PermissionLayout.Place] = [.card, .panel]

    private var samples: [String] {
        ["Yes", "Which database should the new service use?", String(repeating: "word ", count: 60), String(repeating: "x", count: 90),
         "line one\nline two\n\nline four", String(repeating: "한글", count: 40), String(repeating: "日本語の質問", count: 20),
         String(repeating: "😀", count: 40), "אבגד " + String(repeating: "שלום עולם ", count: 12), "مرحبا " + String(repeating: "كيف حالك ", count: 12),
         "⇥ tabbed ⟨U+202E⟩ text", String(repeating: "W", count: 120), "a\n", "e\u{301}e\u{301}e\u{301} " + String(repeating: "abc ", count: 30)]
    }

    private func asking(_ questions: [[String: Any]]) throws -> Asking {
        try #require(Q.parse(questions)?.prompt.asking)
    }

    /// Questions of every shape the card has to lay out.
    private func shapes() throws -> [Asking] {
        let two = [Q.option("Yes", "Do it"), Q.option("No", "")]
        let four = (1...4).map { Q.option("Option number \($0)", "A description of option \($0) that is long enough to wrap onto a second row or even a third one when narrow.") }
        let long = [Q.option(String(repeating: "label ", count: 13) + "label", String(repeating: "note ", count: 40)), Q.option("b", "c")]
        return try [
            asking([Q.question("Short?", header: nil, options: two)]),
            asking([Q.question("Which database should the new service use?", options: four)]),
            asking([Q.question(String(repeating: "A very long question. ", count: 30), options: four)]),
            asking([Q.question("Several?", multiSelect: true, options: four)]),
            asking([Q.question("One?", options: two), Q.question("Two, a longer one than the first, that goes on?", multiSelect: true, options: long),
                    Q.question("Three?\nOn two lines.", header: "", options: four)]),
            asking([Q.question("Q\u{430}?", header: "H\u{430}", options: two)]),
            asking([Q.question("한국어 질문입니다. 어느 쪽이 좋을까요?", header: "선택", options: [Q.option("파랑", "차분하고 시원한 색"), Q.option("빨강", "")])]),
            asking([Q.question("العربية؟", options: [Q.option("نعم", "موافق"), Q.option("لا", "")])]),
        ]
    }

    // MARK: The measure is what is drawn

    @Test func theMeasuredTextIsWhatTheViewDrawsAtTheNarrowestCardAndPanel() {
        let fonts: [(NSFont, Font)] = [(QuestionLayout.questionFont, .system(size: 12)), (QuestionLayout.labelFont, .system(size: 11, weight: .semibold)),
                                       (QuestionLayout.descriptionFont, .system(size: 10))]
        for place in places {
            for (ns, font) in fonts {
                for text in samples {
                    let isolated = PermissionText.isolated(text)
                    let measured = PermissionLayout.height(isolated, font: ns, width: place.scrollWidth)
                    let real = drawn(isolated, font: font, width: place.scrollWidth)
                    #expect(abs(measured - real) <= 1, "\(place), \(ns.pointSize), \(text.prefix(12))…: drawn \(real), measured \(measured)")
                }
            }
        }
    }

    @Test func anAnswersButtonIsAsTallAsItsTextNeedsAndNeverLessThanAButton() throws {
        for asking in try shapes() {
            for place in places {
                for (at, item) in asking.items.enumerated() {
                    for (index, option) in item.options.enumerated() {
                        let height = asking.measure(at, place).options[index]
                        #expect(height >= PermissionLayout.buttonHeight)
                        let width = QuestionLayout.optionTextWidth(multiSelect: item.multiSelect, place: place)
                        let label = drawn(PermissionText.isolated(option.label), font: .system(size: 11, weight: .semibold), width: width)
                        let note = option.description.isEmpty ? 0
                            : drawn(PermissionText.isolated(option.description), font: .system(size: 10), width: width)
                        // What is drawn fits in the button.
                        #expect(2 * QuestionLayout.optionPadding + label + (note > 0 ? 1 + note : 0) <= height + 1,
                                "\(place), \(option.label.prefix(10)): needs \(label + note), button \(height)")
                    }
                }
            }
        }
    }

    // MARK: The answers fill the card

    /// The view drawn at its fitting height in `width`: a way to ask whether a pixel is painted. A scrolling view does not draw
    /// off screen, so only what is outside one can be looked at.
    private func painted<V: View>(_ view: V, width: CGFloat) throws -> (height: Int, at: (Int, Int) -> Bool) {
        let host = NSHostingView(rootView: view.frame(width: width))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (Int(size.height), { x, y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 })
    }

    @Test func anAnswerFillsTheWidthItIsGivenBeyondTheNarrowest() throws {
        let gate = PermissionClickGate()
        let option = Asking.Option(label: "Yes", description: "Do it")
        for multiSelect in [false, true] {
            for width in [PermissionLayout.Place.card.scrollWidth + 42, PermissionLayout.Place.panel.scrollWidth + 96] {
                let view = OptionButton(option: option, height: 36, multiSelect: multiSelect, chosen: false, gate: gate) {}
                let shot = try painted(view, width: width)
                #expect(shot.height == 36)
                #expect(shot.at(Int(width) - 3, 18), "multiSelect \(multiSelect): the button stops short of \(width)")
            }
        }
    }

    @Test func aShorterQuestionKeepsItsButtonsAtTheBottomOfTheSizedHeight() throws {
        let gate = PermissionClickGate()
        let tall = Q.question(String(repeating: "A very long question. ", count: 30), options: (1...4).map { Q.option("Option \($0)", "Note \($0)") })
        let short = Q.question("Short?", header: "H", options: [Q.option("Yes"), Q.option("No")])
        let two = try asking([tall, short])
        let prompt = PermissionPrompt(id: UUID(), asking: two, folder: "proj")
        let view = QuestionBody(prompt: prompt, asking: two, draft: draft(at: 1, in: two), showsTitle: false, stacked: false,
                                place: .card, gate: gate) { _ in }
        let shot = try painted(view, width: PermissionLayout.Place.card.width)
        let middle = Int(PermissionLayout.Place.card.width) / 2
        #expect(shot.at(middle, shot.height - Int(PermissionLayout.buttonHeight) / 2), "the pill is not at the bottom of the \(shot.height) points")
    }

    // MARK: The body is as tall as it was sized for

    private func draft(at step: Int, in asking: Asking) -> QuestionDraft {
        var draft = QuestionDraft()
        for index in 0..<step {
            if asking.items[index].multiSelect {
                _ = draft.apply(.toggle(0), to: asking)
                _ = draft.apply(.submit, to: asking)
            } else {
                _ = draft.apply(.pick(0), to: asking)
            }
        }
        return draft
    }

    @Test func eachQuestionIsAsTallAsItWasSizedFor() throws {
        let gate = PermissionClickGate()
        for asking in try shapes() {
            let prompt = PermissionPrompt(id: UUID(), asking: asking, folder: "proj")
            for place in places {
                for showsTitle in [true, false] {
                    for index in asking.items.indices {
                        let view = QuestionStep(prompt: prompt, asking: asking, draft: draft(at: index, in: asking), showsTitle: showsTitle,
                                                place: place, gate: gate) { _ in }
                        let height = fitting(view, width: place.width).height
                        let sized = QuestionLayout.height(of: asking, index, showsTitle: showsTitle, stacked: false, place: place)
                        #expect(abs(height - sized) <= 1, "\(place), title \(showsTitle), question \(index + 1): drawn \(height), sized \(sized)")
                    }
                }
            }
        }
    }

    @Test func theBodyKeepsTheTallestQuestionsHeightFromOneStepToTheNext() throws {
        let gate = PermissionClickGate()
        for asking in try shapes() {
            let prompt = PermissionPrompt(id: UUID(), asking: asking, folder: "proj")
            for hasNotch in [true, false] {
                let sized = PermissionCard.bodyHeight(for: prompt, hasNotch: hasNotch)
                #expect(sized == asking.items.indices.map {
                    QuestionLayout.height(of: asking, $0, showsTitle: hasNotch, stacked: true, place: .card)
                }.max())
                for index in asking.items.indices {
                    let view = QuestionBody(prompt: prompt, asking: asking, draft: draft(at: index, in: asking), showsTitle: hasNotch, stacked: true,
                                            place: .card, gate: gate) { _ in }.padding(.horizontal, 6)
                    let height = fitting(view, width: PermissionLayout.Place.card.width + 12).height + PermissionLayout.bottomPad
                    #expect(abs(height - sized) <= 1, "notch \(hasNotch), question \(index + 1): drawn \(height), sized \(sized)")
                }
            }
        }
    }

    @Test func thePanelIsAsTallAsTheOpenNotchWasSizedFor() throws {
        let gate = PermissionClickGate()
        for asking in try shapes() {
            let prompt = PermissionPrompt(id: UUID(), asking: asking, folder: "proj")
            for index in asking.items.indices {
                let view = PermissionPanel(prompt: prompt, count: 1, gate: gate, draft: draft(at: index, in: asking), act: { _ in }) { _ in }
                let height = fitting(view, width: PermissionLayout.Place.panel.width).height
                #expect(abs(height - PermissionPanel.height(for: prompt)) <= 1, "question \(index + 1): drawn \(height), sized \(PermissionPanel.height(for: prompt))")
            }
        }
    }

    @Test func theClosedCardIsAsTallAsTheNotchWasSizedForItWithItsTopRow() throws {
        let gate = PermissionClickGate()
        for asking in try shapes() {
            let prompt = PermissionPrompt(id: UUID(), asking: asking, folder: "proj")
            for hasNotch in [true, false] {
                let top: CGFloat = 32
                let card = PermissionCard(prompt: prompt, count: 2, height: top, earWidth: NotchViewModel.hudEarWidth, hasNotch: hasNotch, gate: gate,
                                          draft: draft(at: asking.items.count - 1, in: asking), act: { _ in }) { _ in }
                let height = fitting(card, width: PermissionLayout.Place.card.width + 12).height
                // The padding under the body is the notch's, not the card's.
                let sized = top + PermissionCard.bodyHeight(for: prompt, hasNotch: hasNotch) - PermissionLayout.bottomPad
                #expect(abs(height - sized) <= 1, "notch \(hasNotch): drawn \(height), sized \(sized)")
            }
        }
    }

    // MARK: Nothing is hidden without saying so

    @Test func whatTheScrollingPartLeavesOutIsSaidAndCounted() throws {
        for asking in try shapes() {
            for place in places {
                for (index, _) in asking.items.enumerated() {
                    let measure = asking.measure(index, place)
                    let visible = QuestionLayout.visible(measure, place)
                    #expect(visible == min(measure.content, QuestionLayout.maxScroll(place)))
                    let hidden = PermissionLayout.hiddenRows(content: measure.content, visible: visible)
                    #expect(visible + CGFloat(hidden) * PermissionLayout.rowHeight >= measure.content - 0.5)
                    #expect((hidden > 0) == (measure.content > visible + 0.5))
                }
            }
        }
    }

    @Test func aLongQuestionWithManyAnswersScrollsAndAShortOneDoesNot() throws {
        let long = try asking([Q.question(String(repeating: "A very long question. ", count: 30), options: (1...4).map { Q.option("Option \($0)", "Note \($0)") })])
        let short = try asking([Q.question("Short?", header: nil, options: [Q.option("Yes"), Q.option("No")])])
        for place in places {
            #expect(PermissionLayout.hiddenRows(content: long.measure(0, place).content, visible: QuestionLayout.visible(long.measure(0, place), place)) > 0)
            #expect(QuestionLayout.visible(long.measure(0, place), place) == QuestionLayout.maxScroll(place))
            #expect(PermissionLayout.hiddenRows(content: short.measure(0, place).content, visible: QuestionLayout.visible(short.measure(0, place), place)) == 0)
        }
    }

    @Test func theCardAndThePanelFitTheirWindows() throws {
        // The closed notch is drawn in a window of the open notch's largest height plus 20 points, the open one under its header.
        let window = AppSettings.expandedHeightRange.upperBound + 20
        let tallestTop: CGFloat = 40
        for asking in try shapes() {
            let prompt = PermissionPrompt(id: UUID(), asking: asking, folder: "proj")
            #expect(tallestTop + PermissionCard.bodyHeight(for: prompt, hasNotch: true) <= window, "card")
            #expect(PermissionPanel.height(for: prompt) <= AppSettings.expandedHeightRange.upperBound - tallestTop - 8 - 16, "panel")
        }
    }

    @Test func theChipForUnusualCharactersTakesItsOwnRowOnlyWhereItShows() throws {
        let plain = try asking([Q.question("Which color?")]), flagged = try asking([Q.question("Which café?")])
        #expect(plain.items[0].unusual == false && flagged.items[0].unusual)
        for place in places {
            let (a, b) = (plain.measure(0, place), flagged.measure(0, place))
            #expect(a.flag == 0 && b.flag > 0)
            #expect(abs(b.content - a.content - b.flag - PermissionLayout.gap) <= 0.5)
        }
    }

    // MARK: Languages

    private var languages: [(language: String, table: NSDictionary)] {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: resources.path))?.filter { $0.hasSuffix(".lproj") }.sorted() ?? []
        return folders.compactMap { folder in
            NSDictionary(contentsOfFile: resources.appendingPathComponent(folder).appendingPathComponent("Localizable.strings").path).map { (folder, $0) }
        }.filter { $0.table["Sandbox off"] != nil }
    }

    @Test func everyNewStringIsTranslatedIntoEveryLanguage() {
        let keys = ["Question", "Send", "Next", "Answer in terminal", "Answer permission prompts and questions in the notch"]
        #expect(Set(languages.map(\.language)) == ["de.lproj", "es.lproj", "fr.lproj", "ja.lproj", "ko.lproj", "zh-Hans.lproj"])
        for (language, table) in languages {
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty, "\(language): \(key)")
                if language != "fr.lproj" || key != "Question" { #expect(text != key, "\(language): \(key)") }
            }
            #expect(table["Answer permission prompts in the notch"] == nil, "\(language) still has the old label")
        }
        let ko = languages.first { $0.language == "ko.lproj" }?.table
        #expect(ko?["Question"] as? String == "질문" && ko?["Send"] as? String == "보내기" && ko?["Answer in terminal"] as? String == "터미널에서 답하기")
    }

    @Test func theButtonsFitOneRowInEveryLanguage() {
        for (language, table) in languages {
            for key in ["Answer in terminal", "Send", "Next"] {
                let text = table[key] as? String ?? ""
                let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
                // Two buttons share the narrowest row, with the padding of each; the text may shrink to four fifths.
                #expect(width * 0.8 + 20 <= (PermissionLayout.Place.card.width - 6) / 2, "\(language): \(key) is \(width) wide")
            }
        }
    }
}
