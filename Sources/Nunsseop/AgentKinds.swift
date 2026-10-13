import Foundation

extension AgentKind {
    /// The tool an agent name from a hook, a herdr pane or the board stands for; nil for any other name.
    init?(tool: String?) {
        switch tool?.lowercased() {
        case "claude", "claude-code": self = .claude
        case "codex": self = .codex
        case "pi": self = .pi
        case "omp", "oh-my-pi": self = .omp
        case "gjc", "gajae-code": self = .gjc
        case "omo": self = .omo
        case "opencode": self = .opencode
        default: return nil
        }
    }

    /// As the tools present themselves (`omp --version` says `omp/18.6.0`, `gjc` says `gjc/0.18.5`).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi, .omp, .gjc, .omo: rawValue
        }
    }

    /// pi and the tools that keep its session files (see `PiSessions`).
    var isPiFamily: Bool {
        switch self {
        case .pi, .omp, .gjc, .omo: true
        case .claude, .codex, .opencode: false
        }
    }

    /// Whether its session files say how it handles permissions.
    var reportsMode: Bool { self == .claude || self == .codex }

    /// The command that opens the session again, after `cd` into its folder. `id` must have passed `Resume.isSafeSession`.
    /// omp and gjc take the id as `--resume=<id>`: gjc's value is optional, so a separate word would be a prompt.
    func resumeCommand(session id: String) -> String {
        let quoted = Resume.quote(id)
        switch self {
        case .claude: return "claude --resume \(quoted)"
        case .codex: return "codex resume \(quoted)"
        case .pi: return "pi --session \(quoted)"
        case .omo: return "omo --session \(quoted)"
        case .omp: return "omp --resume=\(quoted)"
        case .gjc: return "gjc --resume=\(quoted)"
        case .opencode: return "opencode -s \(quoted)"
        }
    }
}
