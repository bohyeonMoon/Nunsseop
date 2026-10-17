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
        case "gemini", "gemini-cli", "gemini cli": self = .gemini
        case "copilot", "github-copilot", "github copilot": self = .copilot
        case "agy", "antigravity": self = .agy
        case "cursor", "cursor-agent": self = .cursor
        case "hermes", "hermes-agent": self = .hermes
        case "amp": self = .amp
        default: return nil
        }
    }

    /// As the tools present themselves (`omp --version` says `omp/18.6.0`, `gjc` says `gjc/0.18.5`).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .copilot: "GitHub Copilot"
        case .agy: "Antigravity"
        case .cursor: "Cursor"
        case .hermes: "Hermes"
        case .amp: "Amp"
        case .pi, .omp, .gjc, .omo: rawValue
        }
    }

    /// pi and the tools that keep its session files (see `PiSessions`).
    var isPiFamily: Bool {
        switch self {
        case .pi, .omp, .gjc, .omo: true
        case .claude, .codex, .opencode, .gemini, .copilot, .agy, .cursor, .hermes, .amp: false
        }
    }

    /// Whether one process of the tool can host several sessions at once (the server OpenCode's plugin lives in, a Cursor window with
    /// several conversations, Amp's plugin process, a daemon that runs Antigravity's hooks), so a new session in a process is no sign that
    /// the earlier one in it is over.
    var sharesProcess: Bool {
        switch self {
        case .opencode, .agy, .cursor, .amp: true
        case .claude, .codex, .pi, .omp, .gjc, .omo, .gemini, .copilot, .hermes: false
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
        case .gemini: return "gemini --resume=\(quoted)"
        case .copilot: return "copilot --resume=\(quoted)"
        case .agy: return "agy --resume \(quoted)"
        case .cursor: return "cursor-agent --resume=\(quoted)"
        case .hermes: return "hermes --resume \(quoted)"
        case .amp: return "amp threads continue \(quoted)"
        }
    }
}
