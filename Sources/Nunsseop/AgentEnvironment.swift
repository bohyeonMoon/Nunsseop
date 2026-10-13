import Darwin
import Foundation

/// The terminal variables of a process's own environment, for a session whose hook named no terminal because it started before the
/// hook sent them (Claude Code reads its hook commands once, at the session's start). Only `keys` are ever taken from it.
struct ProcessEnvironment: Sendable {
    /// The variables the hook reads (`agentHookCommand`); nothing else is extracted, kept or logged.
    static let keys: Set<String> = [
        "MUXY_SESSION_ID", "CMUX_SURFACE_ID", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON",
        "ITERM_SESSION_ID", "ORCA_PANE_KEY", "HERDR_PANE_ID", "TMUX", "ZELLIJ", "STY",
    ]

    /// The environment of a process; nil when it can't be read. Tests give it made-up ones.
    var read: @Sendable (Int32) -> [String: String]?

    static let live = ProcessEnvironment { readLive(pid: $0) }

    /// The process's variables among `keys`, whatever `read` gives; empty when it is unreadable.
    func variables(of pid: Int32) -> [String: String] {
        read(pid)?.filter { Self.keys.contains($0.key) } ?? [:]
    }

    /// The most `KERN_PROCARGS2` can hold, bounding the buffer; nil when macOS doesn't say.
    private static var argMax: Int? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return min(Int(value), 4 << 20)
    }

    /// Reads another process's arguments and environment of the same user, which needs no privilege.
    private static func readLive(pid: Int32) -> [String: String]? {
        guard pid > 1, let capacity = argMax else { return nil }
        var buffer = [UInt8](repeating: 0, count: capacity)
        var size = capacity
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0, size <= capacity else { return nil }
        return parse(buffer[..<size])
    }

    /// The variables among `keys` in a `KERN_PROCARGS2` buffer: an `int32` argc, the executable's path, NUL padding, argc argument
    /// strings, then the `NAME=value` strings, each ended by a NUL. A string the buffer cuts off is dropped, not taken short; the
    /// first of a repeated name wins, as in `getenv`. A malformed buffer gives what was found before the flaw, or nothing.
    static func parse(_ buffer: ArraySlice<UInt8>) -> [String: String] {
        let bytes = buffer
        var index = bytes.startIndex
        guard bytes.count > MemoryLayout<Int32>.size else { return [:] }
        var argc: Int32 = 0
        for offset in 0..<MemoryLayout<Int32>.size { argc |= Int32(bytes[index + offset]) << (8 * Int32(offset)) }  // little endian, as the kernel's
        index += MemoryLayout<Int32>.size
        guard (0...Int32(1 << 16)).contains(argc) else { return [:] }
        // The path, then the padding that aligns the arguments.
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc {
            while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
            guard index < bytes.endIndex else { return [:] }
            index += 1
        }
        var found: [String: String] = [:]
        let equals = UInt8(ascii: "=")
        while index < bytes.endIndex {
            guard let end = bytes[index...].firstIndex(of: 0) else { break }
            let entry = bytes[index..<end]
            index = end + 1
            guard let split = entry.firstIndex(of: equals) else { continue }
            let name = String(decoding: entry[..<split], as: UTF8.self)
            if keys.contains(name), found[name] == nil { found[name] = String(decoding: entry[(split + 1)...], as: UTF8.self) }
        }
        return found
    }
}
