import Foundation

/// One terminal surface as Ghostty's AppleScript lists it. Ghostty exports nothing a shell could use as an address, so a session is
/// found among them by its folder (and, among several in one folder, by its name in the tab's Claude title).
struct GhosttyTerminal: Equatable, Sendable {
    let id: String
    /// `working directory`: the shell's current folder, from shell integration; empty when it doesn't say.
    let cwd: String
    /// `name`: the current title, which Claude Code sets to its session's name behind a status mark.
    let name: String
}

/// What one look at Ghostty's terminals came to.
enum GhosttyListing: Equatable, Sendable {
    case terminals([GhosttyTerminal])
    /// macOS refused the Apple Event: Automation hasn't been allowed.
    case notAllowed
    /// Ghostty isn't running, or the script failed.
    case unavailable
}

/// Which terminal a session is in.
enum GhosttyTab: Equatable {
    /// `usesName`: several terminals were in the folder and the session's name told them apart, so the send checks it again.
    case terminal(id: String, usesName: Bool)
    /// Several terminals fit and nothing tells them apart, or another session on the board fits the same ones.
    case ambiguous
    /// No terminal is in the session's folder.
    case absent
}

/// The terminal picked for a row, as the send needs it.
struct GhosttyPick: Equatable, Sendable {
    let terminal: String
    let usesName: Bool
}

/// A session in Ghostty, as the resolution sees it.
struct GhosttySession: Equatable, Sendable {
    let key: String
    let cwd: String
    let name: String?
}

enum Ghostty {
    /// The shortest session name that may tell tabs apart: a shorter one is in too many titles.
    static let shortestName = 4

    /// The name as the scripts take it: itself when long enough to look for in other tabs' titles, else empty.
    static func usableName(_ name: String?) -> String { name.flatMap { $0.count >= shortestName ? $0 : nil } ?? "" }

    /// A folder with `.` and `..` resolved, no repeated or trailing slash and no `/private` before `var`, `tmp` or `etc` (macOS's
    /// symlinks, which one side may spell out and the other not). nil for a path that isn't absolute or holds a control character.
    static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        if parts.count > 1, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

    /// The spellings of a normalized folder the send script accepts for the terminal's folder: with and without the `/private` and a
    /// trailing slash. The script compares text and can't normalize.
    static func spellings(of folder: String) -> [String] {
        let outer = ["/var", "/tmp", "/etc"].contains { folder == $0 || folder.hasPrefix($0 + "/") } ? ["/private" + folder] : []
        return ([folder] + outer).flatMap { $0 == "/" ? [$0] : [$0, $0 + "/"] }
    }

    /// Reads the output of `TerminalScripts.ghosttyList`: a record per terminal, fields apart, none of them holding the separators.
    static func parse(_ listing: String) -> [GhosttyTerminal] {
        listing.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return GhosttyTerminal(id: String(fields[0]), cwd: String(fields[1]), name: String(fields[2]))
        }
    }

    /// Lists the terminals of the Ghostty that is running. Never starts it.
    static func list(scripts: AppleScriptRunner) -> GhosttyListing {
        switch scripts.run(TerminalScripts.ghosttyList()) {
        case .value(let text): .terminals(parse(text))
        case .notAllowed: .notAllowed
        case .failed: .unavailable
        }
    }

    /// The scalars Claude Code's status marks (a spinner, `✳`, `◑`) are among: arrows to miscellaneous symbols, Braille included. The
    /// send script tests the same range, so what is picked here is what it accepts.
    static let markScalars: ClosedRange<UInt32> = 0x2190...0x2BFF

    /// What follows the status mark in a title Claude Code set: one mark, a space, then text. nil for any other title (a path, a command,
    /// a shell's default), which no session's name can be found in.
    static func claudeTitle(_ title: String) -> Substring? {
        var rest = Substring(title)
        guard let mark = rest.popFirst(), mark.unicodeScalars.count == 1, let scalar = mark.unicodeScalars.first, markScalars.contains(scalar.value),
              rest.popFirst() == " ", !rest.isEmpty else { return nil }
        return rest
    }

    /// The terminal one session is in, by itself: those in its folder; if several, those whose Claude title holds its name (if that
    /// is at least `shortestName` characters). Exactly one, or it is ambiguous. The only one in the folder must still look like an
    /// agent's tab (a Claude title), and is not taken when another tab's Claude title holds the session's name but it doesn't: the
    /// session's folder is the transcript's, which the tab's may have left.
    static func resolve(cwd: String, name: String?, in terminals: [GhosttyTerminal]) -> GhosttyTab {
        guard let folder = normalized(cwd) else { return .absent }
        let here = terminals.filter { normalized($0.cwd) == folder }
        let usable = name.flatMap { $0.count >= shortestName ? $0 : nil }
        func named(_ terminal: GhosttyTerminal) -> Bool { usable.map { claudeTitle(terminal.name)?.contains($0) ?? false } ?? false }
        switch here.count {
        case 0: return .absent
        case 1:
            guard claudeTitle(here[0].name) != nil else { return .absent }
            if !named(here[0]), terminals.contains(where: named) { return .ambiguous }
            return .terminal(id: here[0].id, usesName: false)
        default:
            let found = here.filter(named)
            return found.count == 1 ? .terminal(id: found[0].id, usesName: true) : .ambiguous
        }
    }

    /// The terminals of all the sessions in Ghostty. When several share a folder they must each be found, and none the same one:
    /// otherwise every one of them is ambiguous, as telling one of them apart would not make sure it isn't another's.
    static func resolve(_ sessions: [GhosttySession], in terminals: [GhosttyTerminal]) -> [String: GhosttyTab] {
        var tabs = Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, resolve(cwd: $0.cwd, name: $0.name, in: terminals)) })
        let byFolder = Dictionary(grouping: sessions) { normalized($0.cwd) ?? "" }
        for (folder, group) in byFolder where group.count > 1 && !folder.isEmpty {
            let found = group.compactMap { session -> String? in
                if case .terminal(let id, _)? = tabs[session.key] { id } else { nil }
            }
            if found.count == group.count, Set(found).count == found.count { continue }
            if group.allSatisfy({ tabs[$0.key] == GhosttyTab.absent }) { continue }
            for session in group { tabs[session.key] = .ambiguous }
        }
        return tabs
    }
}
