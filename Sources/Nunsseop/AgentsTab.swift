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
        target = Self.target(for: agent)
    }

    var folder: String? { path.map { ($0 as NSString).lastPathComponent } }

    var title: String { folder ?? tool }

    /// The state when it is waiting, then the tool (unless it is the title), the mode when it isn't the default (before
    /// the model, so a long line cuts that off last), model and context used.
    var details: [String] { detailParts.map(\.text) }

    var detailParts: [(text: String, warns: Bool)] {
        var parts: [(text: String, warns: Bool)] = []
        if state == .waiting { parts.append((finished ? String(localized: "Your turn") : String(localized: "Needs input"), false)) }
        if folder != nil { parts.append((tool, false)) }
        if let mode, let label = mode.label { parts.append((label, mode.warns)) }
        if let model { parts.append((AgentTranscript.modelLabel(model), false)) }
        if let tokens { parts.append((AgentTranscript.tokensLabel(tokens), false)) }
        return parts
    }

    var symbol: String { state == .working ? "bolt.fill" : "hand.raised.fill" }
    var tint: Color { state == .working ? .green : .yellow }

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

    /// Waiting first, then working, the most recent change first within each.
    static func sorted(_ rows: [AgentRow]) -> [AgentRow] {
        rows.sorted { a, b in
            if a.state != b.state { return a.state == .waiting }
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
    var isShowing = false {
        didSet { if isShowing && !oldValue { refresh() } }
    }
    /// Transcripts given instead of read, by `Entry.key`: for `--demo-agents`.
    var fixed: [String: AgentTranscript] = [:]

    private let board: AgentBoard
    private let home: () -> URL
    private var transcripts = AgentTranscripts()
    private var loading = false
    private var changedWhileLoading = false
    private var observer: AnyCancellable?

    init(board: AgentBoard, home: @escaping () -> URL = { NotifyIntegration.home }) {
        self.board = board
        self.home = home
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
                Text("Connect Claude Code and Codex in Settings › Alerts to see their sessions here")
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        .surface(RoundedRectangle(cornerRadius: 10), opacity: hovering && row.target != nil ? 0.14 : 0.08)
        .contentShape(Rectangle())
        .onTapGesture { row.target?.perform() }
        .onHover { hovering = $0 }
        .help(row.path.map { Text(verbatim: $0) } ?? (row.target == nil ? Text(verbatim: "") : Text("Go to where it came from")))
    }
}
