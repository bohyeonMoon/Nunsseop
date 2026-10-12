import Combine
import SwiftUI

/// One coding agent session in the Agents tab.
struct AgentRow: Identifiable, Equatable {
    /// Where a click goes: the herdr pane, else the terminal app the session runs in. The hooks say nothing about a
    /// tmux, WezTerm or Muxy pane, so those sessions get their app only.
    enum Target: Equatable {
        case herdr(pane: String, socket: String)
        case app(String)

        func perform() {
            switch self {
            case .herdr(let pane, let socket): Herdr.focus(pane: pane, socket: URL(fileURLWithPath: socket))
            case .app(let id): TerminalFocus.action(app: id, target: nil)?()
            }
        }
    }

    let id: String
    let tool: String
    let state: AgentBoard.State
    let finished: Bool
    let since: Date?
    let path: String?
    let model: String?
    let tokens: Int?
    let mode: AgentMode?
    let name: String?
    let target: Target?

    init(_ entry: AgentBoard.Entry, transcript: AgentTranscript?) {
        let agent = entry.agent
        id = entry.key
        tool = Self.toolName(agent.tool)
        state = agent.state
        finished = agent.finished
        since = agent.since
        path = [agent.cwd, transcript?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty }
        model = transcript?.model
        tokens = transcript?.tokens
        mode = transcript?.mode
        name = transcript?.name
        target = Self.target(for: agent)
    }

    var folder: String? { path.map { ($0 as NSString).lastPathComponent } }

    /// The session's name, else its folder, else the tool.
    var title: String { name ?? folder ?? tool }

    /// The state when it is waiting or idle, then the folder when a name is the title (unless it says the same), the tool
    /// (unless it is the title), the mode when it isn't the default (before the model, so a long line cuts that off
    /// last), model and context used.
    var details: [String] { detailParts.map(\.text) }

    var detailParts: [(text: String, warns: Bool)] {
        var parts: [(text: String, warns: Bool)] = []
        switch state {
        case .waiting: parts.append((finished ? String(localized: "Your turn") : String(localized: "Needs input"), false))
        case .idle: parts.append((String(localized: "Idle"), false))
        case .working: break
        }
        if let name, let folder, folder.caseInsensitiveCompare(name) != .orderedSame { parts.append((folder, false)) }
        if name != nil || folder != nil { parts.append((tool, false)) }
        if let mode, let label = mode.label { parts.append((label, mode.warns)) }
        if let model { parts.append((AgentTranscript.modelLabel(model), false)) }
        if let tokens { parts.append((AgentTranscript.tokensLabel(tokens), false)) }
        return parts
    }

    var symbol: String {
        switch state {
        case .working: "bolt.fill"
        case .waiting: "hand.raised.fill"
        case .idle: "moon.zzz.fill"
        }
    }

    var tint: Color {
        switch state {
        case .working: .green
        case .waiting: .yellow
        case .idle: .white.opacity(0.45)
        }
    }

    /// "Claude Code" and "Codex" for the hooks; herdr's own name for its agent.
    static func toolName(_ raw: String?) -> String {
        switch kind(raw) {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case nil: return raw.flatMap { $0.isEmpty ? nil : $0 } ?? "herdr"
        }
    }

    static func kind(_ tool: String?) -> AgentKind? {
        switch tool?.lowercased() {
        case "claude", "claude-code": .claude
        case "codex": .codex
        default: nil
        }
    }

    /// Where the transcript is looked for; herdr gives the session id of the agent in a pane.
    static func transcriptKey(_ agent: AgentBoard.Agent) -> AgentTranscripts.Key? {
        guard let kind = kind(agent.tool), let session = agent.session else { return nil }
        return AgentTranscripts.Key(kind: kind, session: session)
    }

    static func target(for agent: AgentBoard.Agent) -> Target? {
        if let pane = agent.pane, let socket = agent.socket { return .herdr(pane: pane, socket: socket) }
        return agent.app.map(Target.app)
    }

    /// "<1m", "3m", "2h", "4d": how long ago the state began.
    static func elapsed(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "<1m"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    /// Waiting first, then working, then idle, the most recent change first within each.
    static func sorted(_ rows: [AgentRow]) -> [AgentRow] {
        let rank = { (row: AgentRow) in row.state == .waiting ? 0 : row.state == .working ? 1 : 2 }
        return rows.sorted { a, b in
            if a.state != b.state { return rank(a) < rank(b) }
            let (x, y) = (a.since ?? .distantPast, b.since ?? .distantPast)
            return x != y ? x > y : a.id < b.id
        }
    }
}

/// The board's agents as rows, with what their transcripts say. Transcripts are looked up off the main thread,
/// and only while the tab is showing: on opening it and whenever the board changes, not on a timer.
@MainActor
final class AgentsTabModel: ObservableObject {
    @Published private(set) var rows: [AgentRow] = []
    /// Whether Claude Code or Codex is connected, which tells an empty tab from one waiting for a connection.
    @Published private(set) var connected = false
    var isShowing = false {
        didSet {
            guard isShowing && !oldValue else { return }
            connected = checkConnected()
            refresh()
        }
    }
    /// Transcripts given instead of read, by `Entry.key`: for `--demo-agents`.
    var fixed: [String: AgentTranscript] = [:]

    private let board: AgentBoard
    private let home: () -> URL
    private let isConnected: (() -> Bool)?
    private var transcripts = AgentTranscripts()
    private var loading = false
    private var changedWhileLoading = false
    private var observer: AnyCancellable?

    /// - isConnected: whether a tool is connected; by default, whether Claude Code's or Codex's settings under `home` say so.
    init(board: AgentBoard, home: @escaping () -> URL = { NotifyIntegration.home }, isConnected: (() -> Bool)? = nil) {
        self.board = board
        self.home = home
        self.isConnected = isConnected
        connected = checkConnected()
        #if DEBUG
        if CommandLine.arguments.contains("--demo-agents") { fixed = AgentBoard.demoTranscripts }
        #endif
        observer = board.$revision.sink { [weak self] _ in
            MainActor.assumeIsolated { if self?.isShowing == true { self?.refresh() } }
        }
    }

    func refresh(now: Date = .now) {
        let entries = board.entries(now: now)
        rebuild(entries)
        let keys = Set(entries.compactMap { fixed[$0.key] == nil ? AgentRow.transcriptKey($0.agent) : nil })
        guard !keys.isEmpty else { return transcripts.refresh([], home: home()) }
        guard !loading else { changedWhileLoading = true; return }
        loading = true
        let snapshot = transcripts, home = home()
        Task.detached(priority: .utility) { [weak self] in
            var updated = snapshot
            updated.refresh(keys, home: home)
            await self?.loaded(updated)
        }
    }

    private func loaded(_ updated: AgentTranscripts) {
        transcripts = updated
        loading = false
        rebuild(board.entries())
        if changedWhileLoading {
            changedWhileLoading = false
            refresh()
        }
    }

    private func checkConnected() -> Bool {
        if let isConnected { return isConnected() }
        return NotifyIntegration.$homeOverride.withValue(home()) { NotifyIntegration.claudeCode.isInstalled || NotifyIntegration.codex.isInstalled }
    }

    /// What the tab says when no session is listed.
    var emptyMessage: String {
        connected ? String(localized: "No sessions used in the last 3 hours")
                  : String(localized: "Connect Claude Code and Codex in Settings › Alerts to see their sessions here")
    }

    private func rebuild(_ entries: [AgentBoard.Entry]) {
        let next = AgentRow.sorted(entries.map { entry in
            AgentRow(entry, transcript: fixed[entry.key] ?? AgentRow.transcriptKey(entry.agent).flatMap(transcripts.transcript))
        })
        if next != rows { rows = next }
    }
}

struct AgentsTab: View {
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        Group {
            if model.rows.isEmpty {
                Text(verbatim: model.emptyMessage)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The times count on from the minute they were drawn.
                TimelineView(.everyMinute) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(model.rows) { AgentRowView(row: $0, now: context.date) }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { model.isShowing = true }
        .onDisappear { model.isShowing = false }
    }
}

private struct AgentRowView: View {
    let row: AgentRow
    let now: Date
    @State private var hovering = false

    var body: some View {
        content
            .opacity(row.state == .idle ? 0.6 : 1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .surface(RoundedRectangle(cornerRadius: 10), opacity: hovering && row.target != nil ? 0.14 : 0.08)
            .contentShape(Rectangle())
            .onTapGesture { row.target?.perform() }
            .onHover { hovering = $0 }
            .help(row.path.map { Text(verbatim: $0) } ?? (row.target == nil ? Text(verbatim: "") : Text("Go to where it came from")))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(row.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let elapsed = AgentRow.elapsed(since: row.since, now: now) {
                        Text(verbatim: elapsed).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                }
                if !row.detailParts.isEmpty {
                    row.detailParts.enumerated().reduce(Text(verbatim: "")) { text, item in
                        let part = Text(verbatim: item.element.text)
                        return text + Text(verbatim: item.offset == 0 ? "" : " · ") + (item.element.warns ? part.foregroundStyle(.orange) : part)
                    }
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
        }
    }
}
