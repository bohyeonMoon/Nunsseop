import SwiftUI

/// How much room a prompt takes. The closed notch is sized from this before anything is drawn, so the text is measured
/// with the font and width the view draws it in, never estimated from character counts.
enum PermissionLayout {
    static let noteHeight: CGFloat = 14
    static let titleHeight: CGFloat = 15
    static let buttonHeight: CGFloat = 24
    static let gap: CGFloat = 6
    static let bottomPad: CGFloat = 10

    /// Where a prompt is drawn, with the least width its text has there: the closed card's body is 332 points wide at the
    /// narrowest (380 less the shape's sides and the body's padding), the open panel's 476.
    enum Place {
        case card, panel

        var width: CGFloat { self == .card ? 332 : 476 }
        /// The scrolling text keeps room for a legacy scroll bar whether or not one is drawn.
        var scrollWidth: CGFloat { width - scrollerWidth }
    }

    static let scrollerWidth: CGFloat = 16
    /// The command shows at most this many rows before it scrolls, fewer when the rule to add needs room too.
    static let maxDetailRows = 6
    static let minDetailRows = 3
    static let rowBudget = 6

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let captionFont = NSFont.systemFont(ofSize: 10)
    /// What one row of `codeFont` takes.
    static let rowHeight: CGFloat = lineHeight(of: codeFont)

    /// The height SwiftUI gives a row of `font`: its ascent and descent, each rounded up.
    static func lineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
    }

    /// The truncation of a tool's name and folder: the end of an MCP tool's name says what it does, so the middle goes.
    static let titleTruncation: Text.TruncationMode = .middle

    /// What `text` takes when wrapped in `width` in `font`: the rows AppKit wraps it into, each as tall as SwiftUI draws one.
    static func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let rows = (rect.height / NSLayoutManager().defaultLineHeight(for: font)).rounded()
        return max(1, rows) * lineHeight(of: font)
    }

    /// The heights of what a prompt shows in one place.
    struct Measure: Equatable {
        /// The whole scrolling text in `Place.scrollWidth`.
        let scroll: CGFloat
        /// Every rule, one under the other, in `Place.width`.
        let rules: CGFloat
        /// The line saying where "Always allow" saves, in `Place.width`.
        let caption: CGFloat
    }

    static func measure(scrollText: String, grant: PermissionPrompt.Grant?, place: Place) -> Measure {
        Measure(scroll: height(scrollText, font: codeFont, width: place.scrollWidth),
                rules: grant?.rules.reduce(0) { $0 + height($1, font: codeFont, width: place.width) } ?? 0,
                caption: grant.map { height($0.caption, font: captionFont, width: place.width) } ?? 0)
    }

    static func rows(_ height: CGFloat) -> Int {
        Int((height / rowHeight - 0.01).rounded(.up))
    }

    /// Whether every rule shows whole in the rows the card has for them.
    static func offers(_ grant: PermissionPrompt.Grant, place: Place) -> Bool {
        rows(measure(scrollText: "", grant: grant, place: place).rules) <= PermissionPrompt.Grant.maxRuleRows
    }

    /// The rule "Always allow" would add, only when all of it shows without clipping.
    static func offered(_ prompt: PermissionPrompt, _ place: Place) -> PermissionPrompt.Grant? {
        guard let grant = prompt.grant, rows(prompt.measure(place).rules) <= PermissionPrompt.Grant.maxRuleRows else { return nil }
        return grant
    }

    /// How much of the scrolling text shows: all of it up to some rows, fewer when the rule to add needs room too.
    static func visibleDetail(_ prompt: PermissionPrompt, _ place: Place) -> CGFloat {
        let ruleRows = offered(prompt, place) == nil ? 0 : rows(prompt.measure(place).rules)
        let allowed = min(maxDetailRows, max(minDetailRows, rowBudget - ruleRows))
        return min(prompt.measure(place).scroll, CGFloat(allowed) * rowHeight)
    }

    /// Rows of `content` that `visible` leaves out, 0 when it all shows.
    static func hiddenRows(content: CGFloat, visible: CGFloat) -> Int {
        content > visible + 0.5 ? max(1, rows(content - visible)) : 0
    }

    static func note(hidden: Int) -> String {
        hidden == 1 ? String(localized: "Scroll for the rest: 1 more line") : String(localized: "Scroll for the rest: \(hidden) more lines")
    }

    /// What the body takes below the top row.
    static func height(of prompt: PermissionPrompt, showsTitle: Bool, stacked: Bool, place: Place) -> CGFloat {
        var parts: [CGFloat] = []
        if showsTitle { parts.append(titleHeight) }
        let visible = visibleDetail(prompt, place)
        if visible > 0 {
            let hidden = hiddenRows(content: prompt.measure(place).scroll, visible: visible)
            parts.append(visible + (hidden > 0 ? noteHeight : 0))
        }
        let grant = offered(prompt, place)
        if grant != nil { parts.append(prompt.measure(place).rules + prompt.measure(place).caption) }
        parts.append(buttonHeight)
        if grant != nil && stacked { parts.append(buttonHeight) }
        return parts.reduce(0, +) + gap * CGFloat(parts.count - 1) + (stacked ? bottomPad : 0)
    }
}

/// The question and its answers: what is asked in full, what "Always allow" would add and where, and Deny, Allow and,
/// when it is offered, Always allow. The buttons ignore clicks while the gate says the card is new.
struct PermissionBody: View {
    let prompt: PermissionPrompt
    /// The tool and folder as a line of their own, for a layout whose top row doesn't carry them.
    let showsTitle: Bool
    /// "Always allow" on a row of its own, under the other two, rather than beside them.
    let stacked: Bool
    let place: PermissionLayout.Place
    @ObservedObject var gate: PermissionClickGate
    let answer: (PermissionAnswer) -> Void

    var body: some View {
        let visible = PermissionLayout.visibleDetail(prompt, place)
        let grant = PermissionLayout.offered(prompt, place)
        VStack(alignment: .leading, spacing: PermissionLayout.gap) {
            if showsTitle { PermissionTitle(prompt: prompt) }
            if visible > 0 {
                PermissionDetail(prompt: prompt, visible: visible, planned: prompt.measure(place).scroll)
            }
            if let grant { PermissionGrantNote(grant: grant) }
            HStack(spacing: 6) {
                pill("Deny", fill: .red.opacity(0.18), text: .red, width: grant != nil && !stacked ? 96 : nil) { answer(.deny) }
                pill("Allow", fill: .white, text: .black, width: grant != nil && !stacked ? 96 : nil) { answer(.allow) }
                if grant != nil, !stacked { always }
            }
            if grant != nil, stacked { always }
        }
        .onAppear { gate.arm() }
    }

    private var always: some View {
        pill("Always allow", fill: .white.opacity(0.15), text: .white) { answer(.always) }
    }

    private func pill(_ title: LocalizedStringKey, fill: Color, text: Color, width: CGFloat? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil, minHeight: PermissionLayout.buttonHeight, maxHeight: PermissionLayout.buttonHeight)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(GatedPress(gate: gate))
    }
}

/// Tells the gate when the mouse goes down and comes up on a button, and dims the button while the gate is closed.
private struct GatedPress: ButtonStyle {
    let gate: PermissionClickGate

    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration, gate: gate)
    }

    private struct Pressed: View {
        let configuration: ButtonStyleConfiguration
        @ObservedObject var gate: PermissionClickGate

        var body: some View {
            configuration.label
                .opacity(gate.isReady ? 1 : 0.4)
                .animation(nil, value: gate.isReady)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed { gate.pressBegan() } else { gate.pressEnded() }
                }
        }
    }
}

/// The command, path or input, wrapped and in full: up to a few rows show, and the rest scrolls under a note saying how
/// many more rows there are.
struct PermissionDetail: View {
    let prompt: PermissionPrompt
    let visible: CGFloat
    /// How tall the text was measured to be before it was drawn, used until the drawn text reports its own height.
    let planned: CGFloat
    @State private var drawn: CGFloat?

    var body: some View {
        let hidden = PermissionLayout.hiddenRows(content: drawn ?? planned, visible: visible)
        VStack(alignment: .leading, spacing: PermissionLayout.noteHeight - 12) {
            ScrollView(.vertical) {
                Text(styled)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, PermissionLayout.scrollerWidth)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { Color.clear.preference(key: DrawnHeight.self, value: $0.size.height) })
            }
            .onPreferenceChange(DrawnHeight.self) { drawn = $0 }
            .scrollIndicators(.visible)
            .frame(height: visible)
            if hidden > 0 {
                Text(verbatim: PermissionLayout.note(hidden: hidden))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .frame(height: 12)
            }
        }
    }

    /// Flags first, the sandbox being off in the warning colour, then the detail, then the rest quieter.
    var styled: AttributedString {
        var result = AttributedString()
        func add(_ text: String, _ color: Color) {
            guard !text.isEmpty else { return }
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            var part = AttributedString(text)
            part.foregroundColor = color
            result.append(part)
        }
        for flag in prompt.flags { add(flag.text, flag.warns ? .orange : .white) }
        add(prompt.detail, .white.opacity(0.85))
        add(prompt.secondary, .white.opacity(0.6))
        return result
    }
}

private struct DrawnHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The rules "Always allow" would add, each in full, and where they are saved. Nothing here has a fixed height: the rules
/// and the line under them take what they take, one under the other.
private struct PermissionGrantNote: View {
    let grant: PermissionPrompt.Grant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(grant.rules.enumerated()), id: \.offset) { _, rule in
                Text(verbatim: rule)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Text(verbatim: grant.caption)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// "Run a command" and the folder the session runs in. A name too long for the line loses its middle, never its end.
struct PermissionTitle: View {
    let prompt: PermissionPrompt

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: prompt.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .truncationMode(PermissionLayout.titleTruncation)
            if !prompt.folder.isEmpty {
                Text(verbatim: prompt.folder).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .truncationMode(PermissionLayout.titleTruncation)
            }
        }
        .lineLimit(1)
        .frame(height: PermissionLayout.titleHeight)
    }
}

/// "1 of 3" while prompts queue.
private struct PermissionPosition: View {
    let count: Int

    var body: some View {
        if count > 1 {
            Text("1 of \(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// The closed notch while a prompt waits: the symbol and position in its ears, the question below.
struct PermissionCard: View {
    let prompt: PermissionPrompt
    let count: Int
    let height: CGFloat
    let earWidth: CGFloat
    /// Room kept clear before the symbol, so both ears can sit right of the camera.
    var leadingInset: CGFloat = 0
    /// A display without a camera has room in the top row for the title itself.
    let hasNotch: Bool
    @ObservedObject var gate: PermissionClickGate
    let answer: (PermissionAnswer) -> Void

    static func bodyHeight(for prompt: PermissionPrompt, hasNotch: Bool) -> CGFloat {
        PermissionLayout.height(of: prompt, showsTitle: hasNotch, stacked: true, place: .card)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: prompt.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: hasNotch ? earWidth - 16 : 20, alignment: .leading)
                if hasNotch {
                    Spacer()
                } else {
                    PermissionTitle(prompt: prompt)
                    Spacer(minLength: 0)
                }
                PermissionPosition(count: count)
                    .frame(width: hasNotch ? earWidth - 16 : nil, alignment: .trailing)
            }
            .padding(.leading, leadingInset)
            .frame(height: height)
            PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, place: .card, gate: gate,
                           answer: answer)
                .padding(.horizontal, 6)
        }
    }
}

/// The open notch while a prompt waits, over the tab, which stays where it was underneath.
struct PermissionPanel: View {
    let prompt: PermissionPrompt
    let count: Int
    @ObservedObject var gate: PermissionClickGate
    let answer: (PermissionAnswer) -> Void

    /// What the panel takes: the top row, the gap under it and the body.
    static func height(for prompt: PermissionPrompt) -> CGFloat {
        PermissionLayout.titleHeight + 8 + PermissionLayout.height(of: prompt, showsTitle: false, stacked: false, place: .panel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: prompt.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, alignment: .leading)
                PermissionTitle(prompt: prompt)
                Spacer(minLength: 0)
                PermissionPosition(count: count)
            }
            PermissionBody(prompt: prompt, showsTitle: false, stacked: false, place: .panel, gate: gate,
                           answer: answer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
