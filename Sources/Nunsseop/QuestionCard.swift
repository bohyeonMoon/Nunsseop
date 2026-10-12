import SwiftUI

/// A question and its answers, one question at a time: the chip and the step, the question and its answers scrolling
/// together, and the buttons that are always there. Its height is the tallest question's (`QuestionLayout.height`), so the
/// notch keeps its size from one question to the next. The buttons ignore clicks while the gate says the card is new or has
/// just moved on.
struct QuestionBody: View {
    let prompt: PermissionPrompt
    let asking: Asking
    let draft: QuestionDraft
    let showsTitle: Bool
    let stacked: Bool
    let place: PermissionLayout.Place
    @ObservedObject var gate: PermissionClickGate
    let act: (QuestionAction) -> Void

    var body: some View {
        QuestionStep(prompt: prompt, asking: asking, draft: draft, showsTitle: showsTitle, place: place, gate: gate, act: act)
            .frame(height: QuestionLayout.height(of: asking, showsTitle: showsTitle, stacked: false, place: place), alignment: .top)
            .onAppear { gate.arm() }
    }
}

/// The question being asked, as tall as `QuestionLayout.height(of:_:)` says.
struct QuestionStep: View {
    let prompt: PermissionPrompt
    let asking: Asking
    let draft: QuestionDraft
    let showsTitle: Bool
    let place: PermissionLayout.Place
    @ObservedObject var gate: PermissionClickGate
    let act: (QuestionAction) -> Void

    private var index: Int { min(draft.step, asking.items.count - 1) }

    var body: some View {
        let item = asking.items[index]
        let measure = asking.measure(index, place)
        let visible = QuestionLayout.visible(measure, place)
        let hidden = PermissionLayout.hiddenRows(content: measure.content, visible: visible)
        VStack(alignment: .leading, spacing: PermissionLayout.gap) {
            if showsTitle { PermissionTitle(prompt: prompt) }
            if asking.hasHeaderRow(index) { headerRow(item) }
            VStack(alignment: .leading, spacing: PermissionLayout.noteHeight - 12) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: PermissionLayout.gap) {
                        if item.unusual {
                            Text(verbatim: QuestionLayout.flagText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .frame(height: measure.flag, alignment: .leading)
                        }
                        Text(verbatim: PermissionText.isolated(item.question))
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(spacing: QuestionLayout.optionGap) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { at, option in
                                OptionButton(option: option, height: measure.options[at], multiSelect: item.multiSelect,
                                             chosen: draft.chosen.contains(at), gate: gate) {
                                    act(item.multiSelect ? .toggle(at) : .pick(at))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.trailing, PermissionLayout.scrollerWidth)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id("\(prompt.id)-\(index)")
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
            buttons(item)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func headerRow(_ item: Asking.Item) -> some View {
        HStack(spacing: 6) {
            if !item.header.isEmpty {
                Text(verbatim: PermissionText.isolated(item.header))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: QuestionLayout.headerRowHeight)
                    .background(Capsule().fill(.white.opacity(0.15)))
            }
            Spacer(minLength: 0)
            if asking.items.count > 1 {
                Text(verbatim: "\(index + 1)/\(asking.items.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(height: QuestionLayout.headerRowHeight)
    }

    private func buttons(_ item: Asking.Item) -> some View {
        HStack(spacing: 6) {
            pill(Text("Answer in terminal"), fill: .white.opacity(0.15), text: .white, dimmed: false) { act(.terminal) }
            if item.multiSelect {
                pill(index + 1 < asking.items.count ? Text("Next") : Text("Send"), fill: .white, text: .black,
                     dimmed: draft.chosen.isEmpty) { act(.submit) }
            }
        }
    }

    private func pill(_ title: Text, fill: Color, text: Color, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: PermissionLayout.buttonHeight, maxHeight: PermissionLayout.buttonHeight)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(GatedPress(gate: gate))
        .disabled(dimmed)
    }
}

/// One answer: its label in bold, its description under it, a check when it can be toggled on.
struct OptionButton: View {
    let option: Asking.Option
    let height: CGFloat
    let multiSelect: Bool
    let chosen: Bool
    @ObservedObject var gate: PermissionClickGate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if multiSelect {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(chosen ? Color.white : Color.white.opacity(0.5))
                        .frame(width: QuestionLayout.markWidth, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: PermissionText.isolated(option.label))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.description.isEmpty {
                        Text(verbatim: PermissionText.isolated(option.description))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, QuestionLayout.optionSide)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(chosen ? 0.28 : 0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(GatedPress(gate: gate))
    }
}
