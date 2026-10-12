import AppKit
import Foundation

/// What the card shows of the questions Claude Code asks through `AskUserQuestion`, escaped for drawing. What is sent back is
/// built from the original strings (see `PermissionWire.questionDecision`), never from these.
struct Asking: Equatable {
    struct Option: Equatable {
        let label: String
        /// Clipped; empty when there is none.
        let description: String
    }

    struct Item: Equatable {
        let question: String
        /// The chip above the question, clipped; empty when there is none.
        let header: String
        let options: [Option]
        let multiSelect: Bool
        /// Something shown here can pass for ASCII (see `PermissionText.hasUnusualCharacters`).
        let unusual: Bool
    }

    let items: [Item]
    /// How tall each question's scrolling part is, at the narrowest closed card and at the narrowest open panel.
    let card: [QuestionLayout.Measure]
    let panel: [QuestionLayout.Measure]

    init(items: [Item]) {
        self.items = items
        card = items.map { QuestionLayout.measure($0, place: .card) }
        panel = items.map { QuestionLayout.measure($0, place: .panel) }
    }

    func measure(_ index: Int, _ place: PermissionLayout.Place) -> QuestionLayout.Measure {
        place == .card ? card[index] : panel[index]
    }

    /// The row with the chip and the step. Several questions always have one, to say where the user is.
    func hasHeaderRow(_ index: Int) -> Bool { !items[index].header.isEmpty || items.count > 1 }
}

/// What a click on a question card does.
enum QuestionAction: Equatable {
    /// The answer of a question that takes one.
    case pick(Int)
    /// Adds or takes away an answer of a question that takes several.
    case toggle(Int)
    /// Takes the answers toggled on, and moves on or sends.
    case submit
    /// Lets the terminal ask.
    case terminal
}

/// Where the user is in the questions of one prompt: the question being asked, what is toggled on in it, and what the earlier
/// ones were answered.
struct QuestionDraft: Equatable {
    private(set) var step = 0
    /// Option indexes toggled on in the question being asked, in order.
    private(set) var chosen: [Int] = []
    private(set) var answers: [Int: [Int]] = [:]

    enum Outcome: Equatable {
        case stay, next, terminal
        /// The last question was answered.
        case finished([Int: [Int]])
    }

    mutating func apply(_ action: QuestionAction, to asking: Asking) -> Outcome {
        guard asking.items.indices.contains(step) else { return .stay }
        let item = asking.items[step]
        switch action {
        case .terminal:
            return .terminal
        case .pick(let option):
            guard !item.multiSelect, item.options.indices.contains(option) else { return .stay }
            return record([option], of: asking)
        case .toggle(let option):
            guard item.multiSelect, item.options.indices.contains(option) else { return .stay }
            if let at = chosen.firstIndex(of: option) { chosen.remove(at: at) } else { chosen.append(option); chosen.sort() }
            return .stay
        case .submit:
            guard item.multiSelect, !chosen.isEmpty else { return .stay }
            return record(chosen, of: asking)
        }
    }

    private mutating func record(_ options: [Int], of asking: Asking) -> Outcome {
        answers[step] = options
        guard step + 1 < asking.items.count else { return .finished(answers) }
        step += 1
        chosen = []
        return .next
    }
}

/// How much room a question takes, measured like `PermissionLayout` measures an approval: from the fonts and widths the view
/// draws in, never from character counts. The question and its answers scroll together under the chip and the step, above
/// the buttons that are always there.
enum QuestionLayout {
    static let headerRowHeight: CGFloat = 16
    static let optionGap: CGFloat = 4
    static let optionPadding: CGFloat = 4
    static let optionSide: CGFloat = 10
    /// What the check of an answer that can be toggled takes before its text.
    static let markWidth: CGFloat = 20
    /// An answer's text is measured a little narrower than it is drawn, so it never wraps into more rows than were counted.
    static let textSlack: CGFloat = 2
    static let questionFont = NSFont.systemFont(ofSize: 12)
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let descriptionFont = NSFont.systemFont(ofSize: 10)
    static let flagFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    /// The most the scrolling part shows. The closed notch can't grow past its window, the open one past its tab.
    static func maxScroll(_ place: PermissionLayout.Place) -> CGFloat { place == .card ? 130 : 100 }

    /// What one question's scrolling content takes.
    struct Measure: Equatable {
        /// The "Unusual characters" line; 0 when there is none.
        let flag: CGFloat
        let question: CGFloat
        /// The height of each answer's button.
        let options: [CGFloat]

        var content: CGFloat {
            let list = options.reduce(0, +) + QuestionLayout.optionGap * CGFloat(max(0, options.count - 1))
            let parts = [flag, question, list].filter { $0 > 0 }
            return parts.reduce(0, +) + PermissionLayout.gap * CGFloat(max(0, parts.count - 1))
        }
    }

    /// The width the text of an answer is drawn in.
    static func optionTextWidth(multiSelect: Bool, place: PermissionLayout.Place) -> CGFloat {
        place.scrollWidth - 2 * optionSide - (multiSelect ? markWidth : 0)
    }

    static var flagText: String { String(localized: "Unusual characters") }

    static func measure(_ item: Asking.Item, place: PermissionLayout.Place) -> Measure {
        let text = optionTextWidth(multiSelect: item.multiSelect, place: place) - textSlack
        return Measure(
            flag: item.unusual ? PermissionLayout.height(flagText, font: flagFont, width: place.scrollWidth) : 0,
            question: PermissionLayout.height(PermissionText.isolated(item.question), font: questionFont, width: place.scrollWidth),
            options: item.options.map { option in
                let label = PermissionLayout.height(PermissionText.isolated(option.label), font: labelFont, width: text)
                let note = PermissionLayout.height(PermissionText.isolated(option.description), font: descriptionFont, width: text)
                return max(PermissionLayout.buttonHeight, 2 * optionPadding + label + (note > 0 ? 1 + note : 0))
            })
    }

    /// How much of the scrolling content shows.
    static func visible(_ measure: Measure, _ place: PermissionLayout.Place) -> CGFloat {
        min(measure.content, maxScroll(place))
    }

    /// What the body of question `index` takes below the top row.
    static func height(of asking: Asking, _ index: Int, showsTitle: Bool, stacked: Bool, place: PermissionLayout.Place) -> CGFloat {
        let measure = asking.measure(index, place)
        let visible = visible(measure, place)
        var parts: [CGFloat] = []
        if showsTitle { parts.append(PermissionLayout.titleHeight) }
        if asking.hasHeaderRow(index) { parts.append(headerRowHeight) }
        let hidden = PermissionLayout.hiddenRows(content: measure.content, visible: visible)
        parts.append(visible + (hidden > 0 ? PermissionLayout.noteHeight : 0))
        parts.append(PermissionLayout.buttonHeight)
        return parts.reduce(0, +) + PermissionLayout.gap * CGFloat(parts.count - 1) + (stacked ? PermissionLayout.bottomPad : 0)
    }

    /// The tallest of the questions, so the notch keeps its size from one to the next.
    static func height(of asking: Asking, showsTitle: Bool, stacked: Bool, place: PermissionLayout.Place) -> CGFloat {
        asking.items.indices.map { height(of: asking, $0, showsTitle: showsTitle, stacked: stacked, place: place) }.max() ?? 0
    }
}

extension PermissionPrompt {
    static let maxQuestions = 4
    static let optionRange = 2...4
    /// A label is what the user picks, so it is shown in full or not at all.
    static let labelLimit = 100
    static let optionDescriptionLimit = 200
    static let headerLimit = 24

    /// A question Claude Code is about to ask (PreToolUse of `AskUserQuestion`). Anything that is not exactly the shape it sends is
    /// left to the terminal: one to four questions with text, two to four answers each with a label, texts and flags of their own
    /// types, no question asked twice and no answer offered twice (texts that differ only in whitespace count as the same, and a label has none around it),
    /// no label with a ", " in a question that takes several (the answers are joined by it), and nothing too long to show.
    static func parseQuestion(_ json: [String: Any]) -> Parsed? {
        guard json["tool_name"] as? String == "AskUserQuestion", let input = json["tool_input"] as? [String: Any],
              JSONSerialization.isValidJSONObject(input),
              let asked = input["questions"] as? [Any], (1...maxQuestions).contains(asked.count) else { return nil }
        var items: [Asking.Item] = []
        var texts = Set<String>()
        var shown = 0
        for entry in asked {
            guard let fields = entry as? [String: Any], let text = fields["question"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, texts.insert(lookalikeKey(text)).inserted,
                  let options = fields["options"] as? [Any], optionRange.contains(options.count) else { return nil }
            let header = fields["header"] ?? ""
            guard let header = header as? String, fields["multiSelect"].map(isBool) ?? true else { return nil }
            let multiSelect = (fields["multiSelect"] as? NSNumber)?.boolValue ?? false
            var labels = Set<String>()
            var shownOptions: [Asking.Option] = []
            for option in options {
                guard let option = option as? [String: Any], let label = option["label"] as? String,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      label == label.trimmingCharacters(in: .whitespacesAndNewlines), labels.insert(lookalikeKey(label)).inserted,
                      !(multiSelect && label.contains(", ")),
                      let note = (option["description"] ?? "") as? String else { return nil }
                let shownLabel = PermissionText.escape(label, multiline: false)
                guard shownLabel.unicodeScalars.count <= labelLimit else { return nil }
                shownOptions.append(Asking.Option(label: shownLabel, description: PermissionText.escape(clip(note, optionDescriptionLimit), multiline: true)))
            }
            let shownQuestion = PermissionText.escape(text, multiline: true)
            let shownHeader = PermissionText.escape(clip(header, headerLimit), multiline: false)
            let everything = [shownQuestion, shownHeader] + shownOptions.flatMap { [$0.label, $0.description] }
            shown += everything.reduce(0) { $0 + $1.unicodeScalars.count }
            items.append(Asking.Item(question: shownQuestion, header: shownHeader, options: shownOptions, multiSelect: multiSelect,
                                     unusual: everything.contains(where: PermissionText.hasUnusualCharacters)))
        }
        guard shown <= detailLimit else { return nil }
        let prompt = PermissionPrompt(id: UUID(), asking: Asking(items: items), folder: folderName(json))
        return Parsed(prompt: prompt, suggestion: nil, questionInput: input)
    }

    /// What two texts that differ only in the whitespace around or between their words share, since the card draws them alike.
    private static func lookalikeKey(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `text` cut to `limit` characters with a visible mark, before it is escaped, so no escape is cut in two.
    private static func clip(_ text: String, _ limit: Int) -> String { PermissionText.clipped(text, limit: limit) }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

extension PermissionWire {
    /// What Claude Code reads from a PreToolUse hook that answers a question for the user: allowed, with the input it would have
    /// asked for plus the answers, each under the original text of its question and as the original labels, joined by ", ".
    /// Nil unless `picked` answers every question, one answer for a question that takes one and at least one for the others, all
    /// of them options that exist, none twice.
    static func questionDecision(_ picked: [Int: [Int]], input: [String: Any]) -> Data? {
        guard let asked = input["questions"] as? [[String: Any]], picked.count == asked.count else { return nil }
        var answers: [String: String] = [:]
        for (index, question) in asked.enumerated() {
            guard let text = question["question"] as? String, let options = question["options"] as? [[String: Any]],
                  let chosen = picked[index], !chosen.isEmpty, Set(chosen).count == chosen.count,
                  chosen.allSatisfy(options.indices.contains),
                  chosen.count == 1 || (question["multiSelect"] as? NSNumber)?.boolValue == true else { return nil }
            let labels = chosen.sorted().compactMap { options[$0]["label"] as? String }
            guard labels.count == chosen.count else { return nil }
            answers[text] = labels.joined(separator: ", ")
        }
        var updated = input
        updated["answers"] = answers
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
        // Writing a number that is not finite raises an Objective-C exception, which `try?` does not catch.
        guard JSONSerialization.isValidJSONObject(output) else { return nil }
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
