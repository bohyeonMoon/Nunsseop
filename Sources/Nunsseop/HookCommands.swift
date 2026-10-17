import Foundation

/// What Nunsseop puts in the hook files of GitHub Copilot CLI, Antigravity and Cursor, which are three different shapes. Every command is
/// the one a hook of Claude Code runs (`NotifyServer.toolHookCommand` for the agents count, `permissionHookCommand` for approvals), so a
/// tool that Nunsseop isn't running beside costs it one process that ends at once and prints nothing.
enum HookCommands {
    /// How long a tool lets an event hook run. The hook itself gives up after a second.
    static let eventTimeout = 10
    /// How long it lets a permission hook run: the hook holds a request for up to 590 seconds (see `PermissionGate.holdSeconds`).
    static let permissionTimeout = 600

    private static var base: String { "127.0.0.1:\(NotifyServer.port)" }

    /// Whether a command is one of Nunsseop's: an agent or permission hook by the address it posts to; a notice only by that and the
    /// title it shows, since the same address is what "Copy command for scripts" gives to anything a user writes themselves.
    static func isOurs(command: String, noticeTitles: [String] = []) -> Bool {
        if command.contains("\(base)/agent") || command.contains("\(base)/permission") { return true }
        return command.contains("\(base)/notify") && noticeTitles.contains { command.contains("X-Title: \($0)'") }
    }
}
