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
    /// Control, formatting (zero-width, direction marks and overrides, tags), line and paragraph separators and every space
    /// but U+0020 are written out as `⟨U+202E⟩`, and so are the angle brackets that mark one, so an escape can't be faked.
    /// A line break stays one when `multiline`; otherwise it is escaped too. CR LF counts as one break.
    static func escape(_ text: String, multiline: Bool) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\r", index < scalars.count, scalars[index] == "\n" { continue }
            if scalar == "\n" && multiline {
                result.append(scalar)
                continue
            }
            if needsEscape(scalar) {
                result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "⟨" || scalar == "⟩" { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        case .spaceSeparator: return scalar != " "
        default: return false
        }
    }

    /// How many rows `text` takes in `columns` columns, counting wide characters twice, so it is never fewer than
    /// the view needs.
    static func rows(_ text: String, columns: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let cells = line.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
            return total + max(1, (cells + columns - 1) / columns)
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
    /// The command, path, address or input in full, escaped; line breaks are line breaks.
    let detail: String
    /// The folder the session runs in.
    let folder: String
    /// What "Always allow" would add; nil when it isn't offered.
    let grant: Grant?

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
        static let maxRows = 3
    }

    /// What is too long to show in full is not taken: the terminal asks, and shows all of it.
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
        let (title, symbol, raw) = describe(tool: tool, input: input)
        let detail = PermissionText.escape(raw, multiline: true)
        let shownTitle = PermissionText.escape(title, multiline: false)
        guard detail.count <= detailLimit, shownTitle.count <= titleLimit else { return nil }
        let suggestion = addRulesSuggestion(in: json["permission_suggestions"])
        let grant = suggestion.flatMap(grant(from:))
        let folder = (json["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        let prompt = PermissionPrompt(id: UUID(), title: shownTitle, symbol: symbol, detail: detail,
                                      folder: PermissionText.clipped(PermissionText.escape(folder, multiline: false), limit: 80),
                                      grant: grant)
        return Parsed(prompt: prompt, suggestion: grant == nil ? nil : suggestion)
    }

    /// A known tool says what it does in plain words and shows its one field; any other, or a known one whose field isn't
    /// the text it should be, shows its own name and its whole input.
    private static func describe(tool: String, input: [String: Any]) -> (title: String, symbol: String, detail: String) {
        func field(_ key: String, _ title: String, _ symbol: String) -> (String, String, String)? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            return (title, symbol, value)
        }
        let known: (String, String, String)? = switch tool {
        case "Bash": field("command", String(localized: "Run a command"), "terminal")
        case "Edit", "MultiEdit": field("file_path", String(localized: "Edit a file"), "pencil")
        case "Write": field("file_path", String(localized: "Write a file"), "doc.badge.plus")
        case "NotebookEdit": field("notebook_path", String(localized: "Edit a notebook"), "pencil")
        case "Read": field("file_path", String(localized: "Read a file"), "doc.text")
        case "WebFetch": field("url", String(localized: "Fetch a web page"), "globe")
        case "WebSearch": field("query", String(localized: "Search the web"), "magnifyingglass")
        default: nil
        }
        if let known { return known }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (tool, "puzzlepiece.extension", input.isEmpty ? "" : json)
    }

    /// The first suggestion that adds allow rules; a mode change is never offered.
    static func addRulesSuggestion(in value: Any?) -> [String: Any]? {
        (value as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first { entry in
            entry["type"] as? String == "addRules" && entry["behavior"] as? String == "allow"
                && !((entry["rules"] as? [Any]) ?? []).isEmpty
        }
    }

    /// Every rule as Claude Code writes it, or nil when any part of the suggestion can't be shown as it is: a rule that
    /// needs escaping, one that is missing or odd, a key nobody has seen, too many rules, or a place that isn't known.
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
        guard rules.reduce(0, { $0 + PermissionText.rows($1, columns: PermissionLayout.cardColumns) }) <= Grant.maxRows else { return nil }
        return Grant(rules: rules, place: place)
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
