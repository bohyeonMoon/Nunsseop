import AppKit
import SwiftUI
import Testing
@testable import Nunsseop

/// The closed notch is sized from counted rows before anything is drawn, so the count has to hold against real text.
@MainActor
struct PermissionLayoutTests {
    private func fitting<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingView(rootView: view.frame(width: width)).fittingSize
    }

    private let samples = [
        "ls", "git status && git diff --stat | head -50", String(repeating: "x", count: 47), String(repeating: "x", count: 48),
        String(repeating: "x", count: 49), String(repeating: "word ", count: 60), String(repeating: "W", count: 300),
        String(repeating: "한글", count: 40), String(repeating: "日本語のコマンド", count: 20), String(repeating: "😀", count: 80),
        "a\n\nb\n" + String(repeating: "c", count: 100) + "\nd", String(repeating: "/very/long/path/segment", count: 12),
        String(repeating: "⟨U+200B⟩", count: 30), "    indented\n        more indented\n\tsh",
    ]

    @Test func theRowCountIsNeverBelowWhatTheTextTakesAtTheNarrowestCardAndPanel() {
        // The card's body is 332 points wide at the least (380 less the shape's sides and the body's padding), the panel's 476.
        for (columns, width) in [(PermissionLayout.cardColumns, CGFloat(332)), (PermissionLayout.panelColumns, CGFloat(476))] {
            for text in samples {
                let real = fitting(Text(verbatim: text).font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true), width: width).height
                let counted = CGFloat(PermissionText.rows(text, columns: columns)) * PermissionLayout.rowHeight
                #expect(real <= counted, "\(columns) columns, \(text.prefix(20))…: drawn \(real), counted \(counted)")
            }
        }
    }

    @Test func thePanelIsAsTallAsTheOpenNotchWasSizedFor() {
        let gate = PermissionClickGate()
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(npm run *)"], place: .session),
                                                 .init(rules: ["Bash(git status:*)", "Read(/a/**)", "WebFetch"], place: .userSettings)]
        for grant in grants {
            for detail in ["", "ls", String(repeating: "line of text\n", count: 30), String(repeating: "w", count: 900)] {
                let prompt = prompt(detail, grant: grant)
                let drawn = fitting(PermissionPanel(prompt: prompt, count: 1, gate: gate) { _ in }, width: 476).height
                #expect(abs(drawn - PermissionPanel.height(for: prompt)) <= 1,
                        "\(grant?.rules.count ?? 0) rules, \(detail.count) characters: drawn \(drawn), sized \(PermissionPanel.height(for: prompt))")
            }
        }
    }

    private func prompt(_ detail: String, grant: PermissionPrompt.Grant?) -> PermissionPrompt {
        PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, folder: "proj", grant: grant)
    }

    @Test func theBodyIsAsTallAsTheClosedNotchWasSizedFor() {
        let gate = PermissionClickGate()
        let grants: [PermissionPrompt.Grant?] = [nil, .init(rules: ["Bash(npm run *)"], place: .localSettings),
                                                 .init(rules: ["Bash(git status:*)", "Read(/a/**)", "WebFetch"], place: .userSettings)]
        for grant in grants {
            for detail in ["", "ls", "a\nb\nc\nd", String(repeating: "line of text\n", count: 30), String(repeating: "w", count: 900)] {
                for hasNotch in [true, false] {
                    let prompt = prompt(detail, grant: grant)
                    let view = PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, columns: PermissionLayout.cardColumns,
                                              gate: gate) { _ in }.padding(.horizontal, 6)
                    // The room under the buttons is the shape's, not the body's.
                    let drawn = fitting(view, width: 344).height + PermissionLayout.bottomPad
                    let sized = PermissionCard.bodyHeight(for: prompt, hasNotch: hasNotch)
                    #expect(abs(drawn - sized) <= 1, "\(grant?.rules.count ?? 0) rules, \(detail.count) characters, notch \(hasNotch): drawn \(drawn), sized \(sized)")
                }
            }
        }
    }
}
