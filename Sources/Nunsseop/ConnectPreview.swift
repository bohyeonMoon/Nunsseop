import SwiftUI

/// A comparison of two texts line by line, for showing what connecting a tool changes in its file.
enum LineDiff {
    enum Kind: Equatable { case same, added, removed }

    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    /// What the sheet lists: a line, or a run of unchanged lines folded away until it is clicked open.
    enum Row: Equatable {
        case line(Line)
        case folded([Line])
    }

    /// Beyond this many comparisons the middle of the texts is not matched up: it reads as all removed, then all added.
    private static let comparisonLimit = 4_000_000

    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The lines of both texts in order: shared ones as `after` has them, the others as removed from `before` or added by `after`.
    /// Lines that differ only in the space before a colon are the same line: Nunsseop writes JSON as Foundation does (`"a" : 1`), and
    /// comparing exactly would show every line of a file written as `"a": 1` as changed, when only the hooks are.
    static func compare(_ before: String, _ after: String) -> [Line] {
        let old = lines(of: before), new = lines(of: after)
        let oldKeys = old.map(key), newKeys = new.map(key)
        var start = 0
        while start < old.count, start < new.count, oldKeys[start] == newKeys[start] { start += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, oldKeys[oldEnd - 1] == newKeys[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        var result = new[..<start].map { Line(kind: .same, text: $0) }
        result += middle(old: Array(old[start..<oldEnd]), oldKeys: Array(oldKeys[start..<oldEnd]),
                         new: Array(new[start..<newEnd]), newKeys: Array(newKeys[start..<newEnd]))
        result += new[newEnd...].map { Line(kind: .same, text: $0) }
        return result
    }

    private static func key(_ line: String) -> String { line.replacingOccurrences(of: "\" : ", with: "\": ") }

    /// The longest common subsequence of what is left once the shared start and end are cut off. A line that changed reads removed, then added.
    private static func middle(old: [String], oldKeys: [String], new: [String], newKeys: [String]) -> [Line] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        guard old.count * new.count <= comparisonLimit else {
            return old.map { Line(kind: .removed, text: $0) } + new.map { Line(kind: .added, text: $0) }
        }
        let width = new.count + 1
        var length = [Int32](repeating: 0, count: (old.count + 1) * width)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                length[i * width + j] = oldKeys[i] == newKeys[j] ? length[(i + 1) * width + j + 1] + 1
                    : max(length[(i + 1) * width + j], length[i * width + j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, oldKeys[i] == newKeys[j] {
                result.append(Line(kind: .same, text: new[j]))
                i += 1; j += 1
            } else if i < old.count, j == new.count || length[(i + 1) * width + j] >= length[i * width + j + 1] {
                result.append(Line(kind: .removed, text: old[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: new[j]))
                j += 1
            }
        }
        return result
    }

    /// The lines with each run of unchanged ones cut down to `context` lines beside a change, the rest folded. A run is folded only
    /// when that hides at least `minimumFolded` lines: a fold saying "1 more line" is longer than the line.
    static func rows(_ lines: [Line], context: Int = 2, minimumFolded: Int = 3) -> [Row] {
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .same else {
                rows.append(.line(lines[index]))
                index += 1
                continue
            }
            var end = index
            while end < lines.count, lines[end].kind == .same { end += 1 }
            let run = Array(lines[index..<end])
            let before = index > 0 ? context : 0, after = end < lines.count ? context : 0
            let hidden = run.count - before - after
            if hidden >= minimumFolded {
                rows += run.prefix(before).map(Row.line)
                rows.append(.folded(Array(run.dropFirst(before).dropLast(after))))
                rows += run.suffix(after).map(Row.line)
            } else {
                rows += run.map(Row.line)
            }
            index = end
        }
        return rows
    }
}

/// What connecting a tool would write, worked out before anything is, to show in the sheet that asks first.
struct ConnectRequest: Identifiable {
    struct File: Identifiable {
        let id: String
        /// With the home folder as `~`.
        let path: String
        let backupName: String?
        let created: Bool
        let lines: [LineDiff.Line]
    }

    let tool: NotifyIntegration
    let files: [File]
    var id: String { tool.rawValue }

    /// Nil when connecting would change nothing.
    init?(tool: NotifyIntegration, changes: [NotifyIntegration.FileChange]) {
        guard !changes.isEmpty else { return nil }
        self.tool = tool
        files = changes.map { change in
            File(id: change.url.path, path: Self.shortPath(change.url), backupName: change.makesBackup ? change.url.lastPathComponent + ".nunsseop-backup" : nil,
                 created: !change.existed, lines: LineDiff.compare(change.before ?? "", change.after))
        }
    }

    private static func shortPath(_ url: URL) -> String {
        let home = NotifyIntegration.home.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Asks before a tool's settings are changed, and shows the lines that change.
struct ConnectSheet: View {
    let request: ConnectRequest
    let cancel: () -> Void
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(request.tool.name)?").font(.system(size: 16, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(request.files) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: Self.sentence(for: file)).font(.callout).fixedSize(horizontal: false, vertical: true)
                            DiffBox(lines: file.lines)
                        }
                    }
                }
            }
            .frame(height: Self.listHeight(for: request))
            if request.tool.sharesItsFile && request.files.contains(where: { !$0.created }) {
                Text("Hooks you already had stay as they are. Disconnecting takes out only Nunsseop's lines.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The list takes the room its rows need, up to a height that keeps the sheet within the Settings window.
    static func listHeight(for request: ConnectRequest) -> CGFloat {
        min(request.files.reduce(0) { $0 + CGFloat(LineDiff.rows($1.lines).count) * 16 + 70 }, 340)
    }

    static func sentence(for file: ConnectRequest.File) -> String {
        if file.created { return String(localized: "\(file.path) will be created.") }
        let changes = String(localized: "\(file.path) will change like this.")
        guard let backup = file.backupName else { return changes }
        return changes + " " + String(localized: "The current file is kept as \(backup).")
    }
}

private struct DiffBox: View {
    let lines: [LineDiff.Line]
    @State private var opened: Set<Int> = []

    private static let added = Color(red: 0.35, green: 0.85, blue: 0.45)
    private static let removed = Color(red: 1, green: 0.42, blue: 0.4)

    var body: some View {
        let rows = LineDiff.rows(lines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                switch row {
                case .line(let line):
                    lineView(line)
                case .folded(let hidden):
                    if opened.contains(index) {
                        ForEach(Array(hidden.enumerated()), id: \.offset) { _, line in lineView(line) }
                    } else {
                        Button { opened.insert(index) } label: {
                            Text("… \(hidden.count) more lines")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func lineView(_ line: LineDiff.Line) -> some View {
        let tint: Color = line.kind == .added ? Self.added : line.kind == .removed ? Self.removed : .secondary
        return HStack(spacing: 6) {
            Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(tint).frame(width: 8)
            Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(minHeight: 16)
        .background(line.kind == .same ? Color.clear : tint.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
