import SwiftUI

/// The question and its answers: what is asked, in a line or two, and Deny, Allow and, when Claude Code suggested a
/// rule, Always allow.
struct PermissionBody: View {
    let prompt: PermissionPrompt
    /// The tool and folder as a line of their own, for a layout whose top row doesn't carry them.
    let showsTitle: Bool
    /// "Always allow" on a row of its own, under the other two, rather than beside them.
    let stacked: Bool
    let answer: (PermissionAnswer) -> Void

    static let titleHeight: CGFloat = 15
    static let detailHeight: CGFloat = 30
    static let buttonHeight: CGFloat = 24
    static let gap: CGFloat = 6

    /// What the body takes below the top row, with the room left under the buttons.
    static func height(showsTitle: Bool, hasRule: Bool, stacked: Bool) -> CGFloat {
        var height = detailHeight + gap + buttonHeight + 10
        if showsTitle { height += titleHeight + gap }
        if hasRule && stacked { height += gap + buttonHeight }
        return height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            if showsTitle { PermissionTitle(prompt: prompt) }
            Text(prompt.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: Self.detailHeight, maxHeight: Self.detailHeight, alignment: .topLeading)
                .help(prompt.fullDetail)
            HStack(spacing: 6) {
                pill("Deny", fill: .red.opacity(0.18), text: .red, width: sideBySide ? 96 : nil) { answer(.deny) }
                pill("Allow", fill: .white, text: .black, width: sideBySide ? 96 : nil) { answer(.allow) }
                if let rule = prompt.rule, !stacked { always(rule) }
            }
            if let rule = prompt.rule, stacked { always(rule) }
        }
    }

    /// Deny and Allow keep their own width beside the rule, so the rule gets the room.
    private var sideBySide: Bool { prompt.rule != nil && !stacked }

    private func always(_ rule: String) -> some View {
        pill("Always allow \(rule)", fill: .white.opacity(0.15), text: .white, truncation: .middle) { answer(.always) }
    }

    private func pill(_ title: LocalizedStringKey, fill: Color, text: Color, truncation: Text.TruncationMode = .tail, width: CGFloat? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .lineLimit(1)
                .truncationMode(truncation)
                .padding(.horizontal, 10)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil, minHeight: Self.buttonHeight, maxHeight: Self.buttonHeight)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// "Run a command" and the folder the session runs in.
private struct PermissionTitle: View {
    let prompt: PermissionPrompt

    var body: some View {
        HStack(spacing: 6) {
            Text(prompt.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            if !prompt.folder.isEmpty {
                Text(prompt.folder).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .frame(height: PermissionBody.titleHeight)
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
    let answer: (PermissionAnswer) -> Void

    static func bodyHeight(for prompt: PermissionPrompt, hasNotch: Bool) -> CGFloat {
        PermissionBody.height(showsTitle: hasNotch, hasRule: prompt.rule != nil, stacked: true)
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
            PermissionBody(prompt: prompt, showsTitle: hasNotch, stacked: true, answer: answer)
                .padding(.horizontal, 6)
        }
    }
}

/// The open notch while a prompt waits, in place of the tab.
struct PermissionPanel: View {
    let prompt: PermissionPrompt
    let count: Int
    let answer: (PermissionAnswer) -> Void

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
            PermissionBody(prompt: prompt, showsTitle: false, stacked: false, answer: answer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
