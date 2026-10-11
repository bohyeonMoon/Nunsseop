import CryptoKit
import Foundation

/// How a permission prompt in the notch was answered.
enum PermissionAnswer: Equatable {
    case allow, deny, always
}

/// The messages between Claude Code's PermissionRequest hook and the server. The token never travels: each side proves
/// it knows it with an HMAC-SHA256 keyed by the token, over a domain, the request's nonce and a SHA-256 of what is
/// vouched for, so neither a request nor an answer can be forged or moved to another request.
enum PermissionWire {
    static let requestDomain = "nunsseop-permission-request"
    static let responseDomain = "nunsseop-permission-response"

    /// 16 random bytes as lowercase hex.
    static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func mac(token: String, domain: String, nonce: String, payload: Data) -> String {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let message = Data("\(domain)\n\(nonce)\n\(digest)".utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Sent as `X-Proof`, with the nonce as `X-Nonce`; the payload is the request body.
    static func requestProof(token: String, nonce: String, body: Data) -> String {
        mac(token: token, domain: requestDomain, nonce: nonce, payload: body)
    }

    /// The answer's body is this, a space, and the decision the hook prints.
    static func responseProof(token: String, nonce: String, decision: Data) -> String {
        mac(token: token, domain: responseDomain, nonce: nonce, payload: decision)
    }

    static let denyMessage = "Denied in Nunsseop"

    /// What Claude Code reads from the hook's stdout. `always` echoes the one suggestion the prompt offered.
    static func decision(_ answer: PermissionAnswer, suggestion: [String: Any]?) -> Data? {
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny", "message": denyMessage]
        case .always:
            guard let suggestion else { return nil }
            decision = ["behavior": "allow", "updatedPermissions": [suggestion]]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// What a prompt shows is what the tool would do, so nothing is dropped or joined and nothing invisible is left invisible.
enum PermissionText {
    /// Scalars that draw nothing, or only blank, yet are not Default_Ignorable_Code_Point (or are, on an older Unicode table).
    private static let blanks: Set<UInt32> = Set([0x2800, 0x3164, 0xFFA0, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x034F, 0xFFFC]
        + Array(0xFE00...0xFE0F) + Array(0xE0100...0xE01EF) + Array(0x180B...0x180F))
    /// Letters and signs that draw no width of their own and sit on the character before them, as marks do, though they are
    /// not marks in the Unicode table; they count toward `maxMarks`.
    private static let markLike: Set<UInt32> = Set(Array(0xFE70...0xFE7F) + Array(0xFC5E...0xFC63)
        + [0x0674, 0x0D4E, 0x0EB3, 0x0F88, 0x1843, 0x0F3E, 0x0F3F, 0x0F7F, 0x1A55])
    /// Combining marks that may follow one base character; any further ones are written out.
    static let maxMarks = 2
    /// What a tab is shown as; `⇥` itself is written out, so this can't be faked.
    static let tab = "⇥ "

    /// Text is first put in normalization form C, so a path macOS stored decomposed reads as it was typed. Then control,
    /// formatting (zero-width, direction marks and overrides, tags), every default-ignorable scalar, blanks that draw
    /// nothing (braille blank, Hangul fillers), line and paragraph separators, every space but U+0020, private-use and
    /// unassigned scalars, and combining marks past `maxMarks` on one base are written out as `⟨U+202E⟩`, and so are the
    /// angle brackets that mark one, so an escape can't be faked. A tab is shown as `tab`. What emoji are made of stays:
    /// a variation selector right after an emoji, and a zero-width joiner between two. A line break stays one when
    /// `multiline`; otherwise it is escaped too. CR LF counts as one break.
    static func escape(_ text: String, multiline: Bool) -> String {
        var result = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()
        func flush() {
            guard !run.isEmpty else { return }
            var marks = 0
            for scalar in String(run).precomposedStringWithCanonicalMapping.unicodeScalars {
                if isMark(scalar) {
                    marks += 1
                    if marks > maxMarks { appendEscape(scalar, to: &result) } else { result.append(scalar) }
                } else {
                    marks = 0
                    result.append(scalar)
                }
            }
            run = String.UnicodeScalarView()
        }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        // The scalar just shown as it is, and whether it was a variation selector.
        var previous: Unicode.Scalar?
        var selected = false
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            let next = index < scalars.count ? scalars[index] : nil
            if scalar == "\r", next == "\n" { continue }
            if scalar == "\n" && multiline {
                flush()
                result.append(scalar)
                previous = nil
            } else if scalar == "\t" {
                flush()
                result.append(contentsOf: tab.unicodeScalars)
                previous = nil
            } else if let before = previous, !selected, scalar.value == 0xFE0E || scalar.value == 0xFE0F,
                      before.properties.isEmoji, before.value >= 0x80 || next?.value == 0x20E3 {
                run.append(scalar)
                selected = true
            } else if let before = previous, scalar.value == 0x200D, isEmoji(before), let after = next, isEmoji(after) {
                run.append(scalar)
                previous = scalar
                selected = false
            } else if needsEscape(scalar) {
                flush()
                appendEscape(scalar, to: &result)
                previous = nil
                selected = false
            } else {
                run.append(scalar)
                previous = scalar
                selected = false
            }
        }
        flush()
        return String(result)
    }

    /// An emoji that is not an ASCII digit, `#` or `*`, which are Emoji scalars too but plain text on their own.
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && scalar.value >= 0x80
    }

    /// Every line of `text` between U+2066 and U+2069, so letters that read right to left can't turn the line around or
    /// reorder the clauses around them. It is applied after `escape` has written out the isolates and overrides the text
    /// itself held, in drawing and in measuring alike. A word joiner follows the isolate: without it SwiftUI breaks a
    /// line of Hangul with no spaces right after the isolate, leaving its first row empty and a row taller than measured.
    static func isolated(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { "\u{2066}\u{2060}\($0)\u{2069}" }.joined(separator: "\n")
    }

    private static func appendEscape(_ scalar: Unicode.Scalar, to result: inout String.UnicodeScalarView) {
        result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark
            || markLike.contains(scalar.value)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "⟨" || scalar == "⟩" || scalar == "⇥" { return true }
        if scalar.properties.isDefaultIgnorableCodePoint || blanks.contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return true
        case .spaceSeparator: return scalar != " "
        default: return scalar.properties.isWhitespace && scalar != " "
        }
    }

    /// `text` cut to `limit` characters with a visible mark, for what is only context.
    static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// One tool call waiting for an answer, as the card shows it. Kept in memory only.
struct PermissionPrompt: Identifiable, Equatable {
    let id: UUID
    /// "Run a command", "Edit a file", or a tool's own name as Claude Code sends it.
    let title: String
    let symbol: String
    /// The command, path, address or input in full, escaped; line breaks are line breaks. For a file it is the path and
    /// what goes into the file.
    let detail: String
    /// The tool's whole name when the title is too long to show in full, so it can be read in the scrolling text; else empty.
    let toolLine: String
    /// Facts about the call that change what it does, such as a sandbox that is off; shown above `detail`.
    let flags: [Flag]
    /// Everything else the call carries, escaped, shown after `detail` in a quieter colour: a command's description and any
    /// other field as `key: value`.
    let secondary: String
    /// The folder the session runs in.
    let folder: String
    /// What "Always allow" would add; nil when it isn't offered.
    let grant: Grant?
    /// How tall what it shows is, at the narrowest closed card and at the narrowest open panel.
    let card: PermissionLayout.Measure
    let panel: PermissionLayout.Measure

    struct Flag: Equatable {
        let text: String
        /// Drawn in the warning colour.
        let warns: Bool
    }

    init(id: UUID, title: String, symbol: String, detail: String, flags: [Flag] = [], secondary: String = "", folder: String,
         grant: Grant?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.flags = flags
        self.secondary = secondary
        self.folder = folder
        self.grant = grant
        toolLine = PermissionLayout.titleFits(title, folder: folder) ? "" : "tool: \(title)"
        let text = PermissionText.isolated(Self.scrollText(toolLine: toolLine, flags: flags, detail: detail, secondary: secondary))
        card = PermissionLayout.measure(isolatedText: text, grant: grant, place: .card)
        panel = PermissionLayout.measure(isolatedText: text, grant: grant, place: .panel)
    }

    /// The scrolling text before its lines are isolated: the tool's name if needed, flags, detail and the rest, a line break between.
    var scrollText: String { Self.scrollText(toolLine: toolLine, flags: flags, detail: detail, secondary: secondary) }

    private static func scrollText(toolLine: String, flags: [Flag], detail: String, secondary: String) -> String {
        ([toolLine].filter { !$0.isEmpty } + flags.map(\.text) + [detail, secondary].filter { !$0.isEmpty }).joined(separator: "\n")
    }

    func measure(_ place: PermissionLayout.Place) -> PermissionLayout.Measure {
        place == .card ? card : panel
    }

    /// The one `addRules` suggestion, and only when everything it would add can be shown as it is.
    struct Grant: Equatable {
        enum Place: String {
            case localSettings, projectSettings, userSettings, session

            /// Completes "Always allow saves this …".
            var phrase: String {
                switch self {
                case .localSettings: String(localized: "in this project, just for you")
                case .projectSettings: String(localized: "in this project")
                case .userSettings: String(localized: "everywhere")
                case .session: String(localized: "for this session")
                }
            }
        }

        let rules: [String]
        let place: Place

        static let maxRules = 3
        /// Rows the rules may take on the card; a suggestion that needs more is not offered.
        static let maxRuleRows = 3

        var caption: String { String(localized: "Always allow saves this \(place.phrase)") }
    }

    /// What is too long to show in full is not taken: the terminal asks, and shows all of it. Counted in Unicode scalars.
    static let detailLimit = 20_000
    static let titleLimit = 120

    struct Parsed {
        let prompt: PermissionPrompt
        /// The `addRules` suggestion "Always allow" echoes back; nil unless the prompt offers it.
        let suggestion: [String: Any]?
    }

    /// Questions and plan approvals are answered in the terminal, and so is anything unreadable.
    private static let terminalOnly: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func parse(_ body: Data) -> Parsed? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              json["hook_event_name"] as? String == "PermissionRequest",
              let tool = json["tool_name"] as? String, !tool.isEmpty, !terminalOnly.contains(tool) else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let described = describe(tool: tool, input: input)
        let detail = PermissionText.escape(described.detail, multiline: true)
        let secondary = PermissionText.escape(described.secondary, multiline: true)
        let shownTitle = PermissionText.escape(described.title, multiline: false)
        let shown = detail.unicodeScalars.count + secondary.unicodeScalars.count + described.flags.reduce(0) { $0 + $1.text.unicodeScalars.count }
        guard shown <= detailLimit, shownTitle.unicodeScalars.count <= titleLimit else { return nil }
        let suggestion = addRulesSuggestion(in: json["permission_suggestions"])
        let grant = suggestion.flatMap(grant(from:))
        let folder = (json["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        let prompt = PermissionPrompt(id: UUID(), title: shownTitle, symbol: described.symbol, detail: detail, flags: described.flags,
                                      secondary: secondary,
                                      folder: PermissionText.clipped(PermissionText.escape(folder, multiline: false), limit: 80),
                                      grant: grant)
        return Parsed(prompt: prompt, suggestion: grant == nil ? nil : suggestion)
    }

    private struct Described {
        var title: String
        var symbol: String
        var detail: String
        var flags: [Flag] = []
        var secondary = ""
    }

    /// A known tool says what it does in plain words, shows the field that says what it acts on and the text it would put
    /// there, and lists every other field it was given; any other tool, or a known one whose field isn't the text it
    /// should be, shows its own name and its whole input.
    private static func describe(tool: String, input: [String: Any]) -> Described {
        func label(_ name: String) -> String {
            switch name {
            case "old_string": "old"
            case "new_string": "new"
            default: name
            }
        }
        func known(_ key: String, _ title: String, _ symbol: String, texts: [String] = [], flagged: Bool = false) -> Described? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            var rest = input
            rest[key] = nil
            var described = Described(title: title, symbol: symbol, detail: value)
            for name in texts {
                guard let text = rest[name] as? String else { continue }
                described.detail += "\n\(label(name)):\n\(text)"
                rest[name] = nil
            }
            if let edits = rest["edits"] as? [Any], !edits.isEmpty, edits.allSatisfy({ $0 is [String: Any] }) {
                for (index, edit) in edits.enumerated() {
                    var fields = edit as? [String: Any] ?? [:]
                    described.detail += "\nedit \(index + 1) of \(edits.count):"
                    for name in ["old_string", "new_string"] {
                        guard let text = fields[name] as? String else { continue }
                        described.detail += "\n\(label(name)):\n\(text)"
                        fields[name] = nil
                    }
                    if !fields.isEmpty { described.detail += "\n" + listing(fields).joined(separator: "\n") }
                }
                rest["edits"] = nil
            }
            var extra: [String] = []
            if flagged {
                if let value = rest["dangerouslyDisableSandbox"], isTruthy(value) {
                    described.flags.append(Flag(text: String(localized: "Sandbox off"), warns: true))
                    // A real true is said by the flag; any other form is listed as it came as well.
                    if isTrue(value) { rest["dangerouslyDisableSandbox"] = nil }
                }
                if isTrue(rest["run_in_background"]) {
                    described.flags.append(Flag(text: String(localized: "Runs in the background"), warns: false))
                    rest["run_in_background"] = nil
                }
                if let note = rest["description"] as? String, !note.isEmpty {
                    extra.append("description: \(note)")
                    rest["description"] = nil
                }
            }
            described.secondary = (extra + listing(rest)).joined(separator: "\n")
            return described
        }
        let described: Described? = switch tool {
        case "Bash": known("command", String(localized: "Run a command"), "terminal", flagged: true)
        case "Edit", "MultiEdit": known("file_path", String(localized: "Edit a file"), "pencil", texts: ["old_string", "new_string"])
        case "Write": known("file_path", String(localized: "Write a file"), "doc.badge.plus", texts: ["content"])
        case "NotebookEdit": known("notebook_path", String(localized: "Edit a notebook"), "pencil", texts: ["new_source"])
        case "Read": known("file_path", String(localized: "Read a file"), "doc.text")
        case "WebFetch": known("url", String(localized: "Fetch a web page"), "globe")
        case "WebSearch": known("query", String(localized: "Search the web"), "magnifyingglass")
        default: nil
        }
        if let described { return described }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Described(title: tool, symbol: "puzzlepiece.extension", detail: input.isEmpty ? "" : json)
    }

    /// A real JSON `true`.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Anything a tool may read as true: `true`, the string "true" in any case, a number that isn't zero.
    private static func isTruthy(_ value: Any) -> Bool {
        if isTrue(value) { return true }
        if let text = value as? String { return text.lowercased() == "true" }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue != 0
    }

    /// Every field as `key: value`, in key order; text as it is, anything else as JSON.
    private static func listing(_ fields: [String: Any]) -> [String] {
        fields.keys.sorted().map { key in
            let value = fields[key] as Any
            if let text = value as? String { return "\(key): \(text)" }
            let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) }
            return "\(key): \(json ?? "\(value)")"
        }
    }

    /// The first suggestion that adds allow rules; a mode change is never offered.
    static func addRulesSuggestion(in value: Any?) -> [String: Any]? {
        (value as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first { entry in
            entry["type"] as? String == "addRules" && entry["behavior"] as? String == "allow"
                && !((entry["rules"] as? [Any]) ?? []).isEmpty
        }
    }

    /// Every rule as Claude Code writes it, or nil when any part of the suggestion can't be shown as it is: a rule that
    /// needs escaping, one that is missing or odd, a key nobody has seen, too many rules, rules that take more rows than the
    /// card has for them, or a place that isn't known.
    static func grant(from suggestion: [String: Any]) -> Grant? {
        guard Set(suggestion.keys).isSubset(of: ["type", "behavior", "rules", "destination"]),
              let place = (suggestion["destination"] as? String).flatMap(Grant.Place.init(rawValue:)),
              let entries = suggestion["rules"] as? [Any], (1...Grant.maxRules).contains(entries.count) else { return nil }
        var rules: [String] = []
        for entry in entries {
            guard let rule = entry as? [String: Any], Set(rule.keys).isSubset(of: ["toolName", "ruleContent"]),
                  let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
            var text = tool
            if let content = rule["ruleContent"] {
                guard let content = content as? String, !content.isEmpty else { return nil }
                text += "(\(content))"
            }
            guard PermissionText.escape(text, multiline: false) == text else { return nil }
            rules.append(text)
        }
        let grant = Grant(rules: rules, place: place)
        guard PermissionLayout.offers(grant, place: .card) else { return nil }
        return grant
    }

    #if DEBUG
    /// `--demo-permission` shows this.
    static var demo: PermissionPrompt {
        PermissionPrompt(id: UUID(), title: String(localized: "Run a command"), symbol: "terminal",
                         detail: "npm run build && npm test -- --coverage", folder: "nunsseop-web",
                         grant: Grant(rules: ["Bash(npm run *)"], place: .localSettings))
    }
    #endif
}

/// Keeps a click from answering a prompt it was not meant for: a card that has just appeared, or just changed, may be
/// under a click aimed at something else. Buttons ignore clicks for `delay` after that, and a click whose mouse-down
/// came before the end of it doesn't count either, however late its mouse-up is.
@MainActor
final class PermissionClickGate: ObservableObject {
    static let delay: TimeInterval = 0.7

    /// Whether the buttons are live; they look dimmed until then.
    @Published private(set) var isReady = false
    private let clock: () -> TimeInterval
    private var readyAt = TimeInterval.infinity
    private var pressedAt: TimeInterval?
    private var wake: DispatchWorkItem?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// The card appeared or its prompt changed.
    func arm() {
        readyAt = clock() + Self.delay
        isReady = false
        schedule(after: Self.delay)
    }

    /// The mouse went down on a button.
    func pressBegan() {
        pressedAt = clock()
    }

    /// The mouse came up. The click's own action runs first, so what it saw is dropped a moment later.
    func pressEnded() {
        let pressed = pressedAt
        DispatchQueue.main.async { [self] in
            if pressedAt == pressed { pressedAt = nil }
        }
    }

    /// Whether the click that just happened counts. A press and a release are two clocks apart in a test, so both are read.
    func accepts() -> Bool {
        refresh()
        guard isReady else { return false }
        if let pressedAt, pressedAt < readyAt { return false }
        return true
    }

    /// `isReady` from the clock.
    func refresh() {
        isReady = clock() >= readyAt
    }

    private func schedule(after seconds: TimeInterval) {
        wake?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if !self.isReady { self.schedule(after: max(self.readyAt - self.clock(), 0.02)) }
            }
        }
        wake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The prompts waiting for an answer, oldest first. A prompt leaves when it is answered or when its hook is gone
/// (the terminal answered first, Claude Code stopped it, or it timed out).
@MainActor
final class PermissionBoard: ObservableObject {
    @Published private(set) var prompts: [PermissionPrompt] = [] {
        didSet { if prompts.first != oldValue.first, prompts.first != nil { gate.arm() } }
    }
    let gate: PermissionClickGate
    /// Hands an answer to the server, which holds the hook's connection.
    var onAnswer: ((UUID, PermissionAnswer) -> Void)?

    init(gate: PermissionClickGate? = nil) {
        self.gate = gate ?? PermissionClickGate()
    }

    var current: PermissionPrompt? { prompts.first }

    func add(_ prompt: PermissionPrompt) {
        prompts.append(prompt)
    }

    /// An answer by a click on the card, which counts only when the gate lets it.
    func answerByClick(_ prompt: PermissionPrompt, _ answer: PermissionAnswer) {
        guard gate.accepts() else { return }
        self.answer(prompt, answer)
    }

    func answer(_ prompt: PermissionPrompt, _ answer: PermissionAnswer) {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        remove(prompt.id)
        onAnswer?(prompt.id, answer)
    }

    func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    func clear() {
        prompts = []
    }
}
