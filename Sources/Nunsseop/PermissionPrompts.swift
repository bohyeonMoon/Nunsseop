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

/// One tool call waiting for an answer, as the card shows it. Kept in memory only.
struct PermissionPrompt: Identifiable, Equatable {
    let id: UUID
    /// "Run a command", "Edit a file", or an MCP tool's name.
    let title: String
    let symbol: String
    /// The command, path or address, on one line.
    let detail: String
    /// Everything of it that is kept, for the tooltip.
    let fullDetail: String
    /// The folder the session runs in.
    let folder: String
    /// The rule "Always allow" would add, as `Bash(npm run *)`; nil when Claude Code suggested none.
    let rule: String?

    static let detailLimit = 400
    static let fullLimit = 2_000

    struct Parsed {
        let prompt: PermissionPrompt
        /// The `addRules` suggestion "Always allow" echoes back.
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
        let suggestion = addRulesSuggestion(in: json["permission_suggestions"])
        let folder = (json["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        let prompt = PermissionPrompt(id: UUID(), title: clean(title, limit: 80), symbol: symbol, detail: clean(raw, limit: detailLimit),
                                      fullDetail: clean(raw, limit: fullLimit), folder: clean(folder, limit: 80),
                                      rule: suggestion.flatMap(ruleText))
        return Parsed(prompt: prompt, suggestion: suggestion)
    }

    private static func describe(tool: String, input: [String: Any]) -> (title: String, symbol: String, detail: String) {
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        switch tool {
        case "Bash": return (String(localized: "Run a command"), "terminal", string("command"))
        case "Edit", "MultiEdit": return (String(localized: "Edit a file"), "pencil", string("file_path"))
        case "Write": return (String(localized: "Write a file"), "doc.badge.plus", string("file_path"))
        case "NotebookEdit": return (String(localized: "Edit a notebook"), "pencil", string("notebook_path"))
        case "Read": return (String(localized: "Read a file"), "doc.text", string("file_path"))
        case "WebFetch": return (String(localized: "Fetch a web page"), "globe", string("url"))
        case "WebSearch": return (String(localized: "Search the web"), "magnifyingglass", string("query"))
        default:
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return (mcpName(tool) ?? tool, "puzzlepiece.extension", json == "{}" ? "" : json)
        }
    }

    /// "github · create_issue" for `mcp__github__create_issue`.
    static func mcpName(_ tool: String) -> String? {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return nil }
        return parts[1] + " · " + parts.dropFirst(2).joined(separator: "__")
    }

    /// The first suggestion that adds allow rules; a mode change is never offered.
    static func addRulesSuggestion(in value: Any?) -> [String: Any]? {
        (value as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first { entry in
            entry["type"] as? String == "addRules" && entry["behavior"] as? String == "allow"
                && !((entry["rules"] as? [Any]) ?? []).isEmpty
        }
    }

    static func ruleText(_ suggestion: [String: Any]) -> String? {
        let rules = ((suggestion["rules"] as? [Any]) ?? []).compactMap { rule -> String? in
            guard let rule = rule as? [String: Any], let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
            guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
            return "\(tool)(\(content))"
        }
        return rules.isEmpty ? nil : clean(rules.joined(separator: ", "), limit: 120)
    }

    /// One line without control or invisible formatting characters, so a command can't draw itself as something else.
    static func clean(_ text: String, limit: Int) -> String {
        var result = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                space = !result.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .format { continue }
            if space { result.append(" ") }
            space = false
            result.append(scalar)
            if result.count > limit { break }
        }
        let line = String(result)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    #if DEBUG
    /// `--demo-permission` shows this.
    static var demo: PermissionPrompt {
        PermissionPrompt(id: UUID(), title: String(localized: "Run a command"), symbol: "terminal", detail: "npm run build && npm test -- --coverage",
                         fullDetail: "npm run build && npm test -- --coverage", folder: "nunsseop-web", rule: "Bash(npm run *)")
    }
    #endif
}

/// The prompts waiting for an answer, oldest first. A prompt leaves when it is answered or when its hook is gone
/// (the terminal answered first, Claude Code stopped it, or it timed out).
@MainActor
final class PermissionBoard: ObservableObject {
    @Published private(set) var prompts: [PermissionPrompt] = []
    /// Hands an answer to the server, which holds the hook's connection.
    var onAnswer: ((UUID, PermissionAnswer) -> Void)?

    var current: PermissionPrompt? { prompts.first }

    func add(_ prompt: PermissionPrompt) {
        prompts.append(prompt)
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
