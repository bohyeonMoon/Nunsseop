import SwiftUI

/// How much room a prompt takes. The closed notch is sized from this before anything is drawn, so rows are counted, never
/// measured, and counted high: a row too many leaves a little space, a row too few would scroll without saying so.
enum PermissionLayout {
    static let rowHeight: CGFloat = 14
    static let noteHeight: CGFloat = 14
    static let captionHeight: CGFloat = 26
    static let titleHeight: CGFloat = 15
    static let buttonHeight: CGFloat = 24
    static let gap: CGFloat = 6
    static let bottomPad: CGFloat = 10

    /// Monospaced 11 pt columns that fit the closed card at its narrowest, and the open panel at its narrowest.
    static let cardColumns = 48
    static let panelColumns = 64
    /// The command shows at most this many rows before it scrolls, fewer when the rule to add needs room too.
    static let maxDetailRows = 6
    static let rowBudget = 6

    static func ruleRows(_ prompt: PermissionPrompt, columns: Int) -> Int {
        prompt.grant?.rules.reduce(0) { $0 + PermissionText.rows($1, columns: columns) } ?? 0
    }

    /// Rows of the command that show; the rest scrolls.
    static func detailRows(_ prompt: PermissionPrompt, columns: Int) -> Int {
        let all = PermissionText.rows(prompt.detail, columns: columns)
        return min(all, maxDetailRows, max(3, rowBudget - ruleRows(prompt, columns: columns)))
    }

    static func overflows(_ prompt: PermissionPrompt, columns: Int) -> Bool {
        PermissionText.rows(prompt.detail, columns: columns) > detailRows(prompt, columns: columns)
    }

    /// What the body takes below the top row.
    static func height(of prompt: PermissionPrompt, showsTitle: Bool, stacked: Bool, columns: Int) -> CGFloat {
        var parts: [CGFloat] = []
        if showsTitle { parts.append(titleHeight) }
        let rows = detailRows(prompt, columns: columns)
        if rows > 0 { parts.append(CGFloat(rows) * rowHeight + (overflows(prompt, columns: columns) ? noteHeight : 0)) }
        if prompt.grant != nil { parts.append(CGFloat(ruleRows(prompt, columns: columns)) * rowHeight + captionHeight) }
        parts.append(buttonHeight)
        if prompt.grant != nil && stacked { parts.append(buttonHeight) }
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
    let columns: Int
    @ObservedObject var gate: PermissionClickGate
    let answer: (PermissionAnswer) -> Void

    var body: some View {
        let rows = PermissionLayout.detailRows(prompt, columns: columns)
        VStack(alignment: .leading, spacing: PermissionLayout.gap) {
            if showsTitle { PermissionTitle(prompt: prompt) }
            if rows > 0 {
                PermissionDetail(text: prompt.detail, rows: rows, overflows: PermissionLayout.overflows(prompt, columns: columns))
            }
            if let grant = prompt.grant {
                PermissionGrantNote(grant: grant, rows: PermissionLayout.ruleRows(prompt, columns: columns))
            }
            HStack(spacing: 6) {
                pill("Deny", fill: .red.opacity(0.18), text: .red, width: sideBySide ? 96 : nil) { answer(.deny) }
                pill("Allow", fill: .white, text: .black, width: sideBySide ? 96 : nil) { answer(.allow) }
                if prompt.grant != nil, !stacked { always }
            }
            if prompt.grant != nil, stacked { always }
        }
        .onAppear { gate.arm() }
    }

    /// Deny and Allow keep their own width beside Always allow, so it gets the room.
    private var sideBySide: Bool { prompt.grant != nil && !stacked }

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
/// much more there is.
private struct PermissionDetail: View {
    let text: String
    let rows: Int
    let overflows: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PermissionLayout.noteHeight - 12) {
            ScrollView(.vertical) {
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .frame(height: CGFloat(rows) * PermissionLayout.rowHeight)
            if overflows {
                Text("Scroll for the rest: \(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines, \(text.count) characters")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .frame(height: 12)
            }
        }
    }
}

/// The rules "Always allow" would add, each in full, and where they are saved.
private struct PermissionGrantNote: View {
    let grant: PermissionPrompt.Grant
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grant.rules.enumerated()), id: \.offset) { _, rule in
                    Text(verbatim: rule)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: CGFloat(rows) * PermissionLayout.rowHeight, alignment: .topLeading)
            Text("Always allow saves this \(grant.place.phrase)")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: PermissionLayout.captionHeight, maxHeight: PermissionLayout.captionHeight, alignment: .topLeading)
        }
    }
}

/// "Run a command" and the folder the session runs in.
private struct PermissionTitle: View {
    let prompt: PermissionPrompt

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: prompt.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            if !prompt.folder.isEmpty {
                Text(verbatim: prompt.folder).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
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
        PermissionLayout.height(of: prompt, showsTitle: hasNotch, stacked: true, columns: PermissionLayout.cardColumns)
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
            PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, columns: PermissionLayout.cardColumns, gate: gate,
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
        PermissionLayout.titleHeight + 8 + PermissionLayout.height(of: prompt, showsTitle: false, stacked: false, columns: PermissionLayout.panelColumns)
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
            PermissionBody(prompt: prompt, showsTitle: false, stacked: false, columns: PermissionLayout.panelColumns, gate: gate,
                           answer: answer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
