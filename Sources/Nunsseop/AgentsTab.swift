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
    /// Where the terminal takes text from outside, if it has an API for that, as the hook named it: see `offersInput`.
    let input: AgentInput?
    /// The tool's process, which `input` is checked against.
    let pid: Int32?
    /// Whether `AgentTargetCheck` found the session's process in the terminal `input` names.
    let inputVerified: Bool
    /// A prompt may be open in the terminal this row types into: the session's own, however long it has waited, or that of
    /// another listed session sharing the terminal (`claude -p` started from it, a Codex session it replaced).
    private(set) var promptOnTerminal: Bool

    init(_ entry: AgentBoard.Entry, transcript: AgentTranscript?, inputVerified: Bool = false) {
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
        input = agent.input
        pid = agent.pid
        self.inputVerified = inputVerified
        promptOnTerminal = agent.promptMayBeOpen
    }

    /// Whether the row offers the message bubble and takes drops: its terminal has an input API and the session is in it. A herdr
    /// pane comes from herdr's own list; any other target is the hook's word, so it counts once it is verified.
    var offersInput: Bool {
        switch input {
        case nil: false
        case .herdr: true
        case .muxy, .cmux: inputVerified
        }
    }

    /// Whether text can be sent to the session now: its terminal has an input API and no prompt may be waiting there.
    var acceptsInput: Bool { offersInput && !promptOnTerminal && AgentSend.accepts(state: state, finished: finished) }

    /// Its terminal takes input, but a prompt waits for the answer first.
    var inputBlocked: Bool { offersInput && !acceptsInput }

    /// The rows with `promptOnTerminal` set on every one whose terminal another row's prompt may be open in: text typed there
    /// answers that dialog, whichever session the row it was typed from belongs to.
    static func sharingTerminals(_ rows: [AgentRow]) -> [AgentRow] {
        let asking = rows.filter(\.promptOnTerminal).compactMap(\.input)
        guard !asking.isEmpty else { return rows }
        return rows.map { row in
            var row = row
            if let input = row.input, asking.contains(input) { row.promptOnTerminal = true }
            return row
        }
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
    /// Conversations that aren't open, to pick up again; listed below the rows.
    @Published private(set) var recent: [RecentConversation] = []
    /// Whether the first look for them is done; until then an empty list doesn't mean there are none.
    @Published private(set) var recentLoaded = false
    /// Whether Claude Code or Codex is connected, which tells an empty tab from one waiting for a connection.
    @Published private(set) var connected = false
    /// The row whose message field is open; one at a time.
    @Published private(set) var composing: String?
    /// A short note under a row whose message or files didn't go out, by `AgentRow.id`.
    @Published private(set) var notes: [String: String] = [:]
    var isShowing = false {
        didSet {
            if !isShowing { composing = nil }
            guard isShowing && !oldValue else { return }
            connected = checkConnected()
            refresh()
        }
    }
    /// Transcripts given instead of read, by `Entry.key`: for `--demo-agents`.
    var fixed: [String: AgentTranscript] = [:]
    /// Recent conversations given instead of read: for `--demo-agents`.
    var fixedRecent: [RecentConversation]?

    private let board: AgentBoard
    private let home: () -> URL
    private let isConnected: (() -> Bool)?
    private let onResume: (RecentConversation) -> Void
    private let scratch: [String]
    private let sender: AgentSender
    private let clis: () -> TerminalCLIs
    private let targets: AgentTargetCheck
    private var transcripts = AgentTranscripts()
    private var loading = false
    private var changedWhileLoading = false
    /// The rows whose terminal target has been verified, by `Entry.key`, for the input and process it was verified for.
    private var verifiedTargets: [String: VerifiedTarget] = [:]
    /// Whether targets are being checked (off the main thread); one pass at a time, one more wanted if the board changed meanwhile.
    private(set) var verifying = false
    private var verifyWanted = false
    /// The time of the latest refresh, which the rows built when a check or a transcript load ends are as of.
    private var asOf = Date.now

    private struct VerifiedTarget: Equatable {
        let input: AgentInput
        let pid: Int32?
    }
    private var scanner = RecentConversations()
    private var scanning = false
    private var scanWanted = false
    private var observer: AnyCancellable?
    /// When each conversation was last clicked, which is how a repeat click is told from a first one.
    private var opening: [String: Date] = [:]
    /// How long a click on the same conversation is ignored: the terminal takes a while to start, cmux up to 10 s.
    static let openingWindow: TimeInterval = 15

    /// - isConnected: whether a tool is connected; by default, whether Claude Code's or Codex's settings under `home` say so.
    /// - scratch: folders whose conversations are left out.
    /// - onResume: what clicking a recent conversation does; by default, opens it in the terminal chosen in Settings.
    /// - sender: what puts text into a terminal; tests give it one that records instead.
    /// - clis: where the terminals' command-line tools are, looked up on every send.
    /// - targets: how a session's terminal is verified; tests give it a made-up process tree.
    init(board: AgentBoard, home: @escaping () -> URL = { NotifyIntegration.home }, isConnected: (() -> Bool)? = nil,
         scratch: [String] = RecentConversations.scratch, onResume: @escaping (RecentConversation) -> Void = Resume.inChosenTerminal,
         sender: AgentSender = .live, clis: @escaping () -> TerminalCLIs = { .live }, targets: AgentTargetCheck = .live) {
        self.board = board
        self.home = home
        self.isConnected = isConnected
        self.onResume = onResume
        self.scratch = scratch
        self.sender = sender
        self.clis = clis
        self.targets = targets
        connected = checkConnected()
        #if DEBUG
        if CommandLine.arguments.contains("--demo-agents") {
            fixed = AgentBoard.demoTranscripts
            fixedRecent = AgentBoard.demoRecent()
        }
        #endif
        observer = board.$revision.sink { [weak self] _ in
            MainActor.assumeIsolated { if self?.isShowing == true { self?.refresh() } }
        }
    }

    func refresh(now: Date = .now) {
        asOf = now
        let entries = board.entries(now: now)
        rebuild(entries)
        verifyTargets(entries)
        refreshRecent(entries, now: now)
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
        rebuild(board.entries(now: asOf))
        if changedWhileLoading {
            changedWhileLoading = false
            refresh()
        }
    }

    /// Checks, off the main thread, that each session's process runs in the terminal its hook named (see `AgentTargetCheck`); until
    /// then, or when it doesn't, the row offers no input. Muxy's session list is read once for all of them.
    private func verifyTargets(_ entries: [AgentBoard.Entry]) {
        let candidates = entries.compactMap { entry -> (key: String, target: VerifiedTarget)? in
            guard let input = entry.agent.input, !isHerdr(input) else { return nil }
            return (entry.key, VerifiedTarget(input: input, pid: entry.agent.pid))
        }
        guard !candidates.isEmpty else {
            if !verifiedTargets.isEmpty { verifiedTargets = [:] }
            return
        }
        guard !verifying else { verifyWanted = true; return }
        verifying = true
        let targets = targets, muxy = clis().muxy, others = Set(entries.compactMap { $0.agent.pid })
        Task.detached(priority: .utility) { [weak self] in
            let wantsList = candidates.contains { if case .muxy = $0.target.input { true } else { false } }
            let sessions = wantsList ? targets.muxySessions(cli: muxy) : nil
            let verified = candidates.filter { targets.verified($0.target.input, pid: $0.target.pid, muxySessions: sessions, others: others) }
            await self?.verified(Dictionary(uniqueKeysWithValues: verified.map { ($0.key, $0.target) }))
        }
    }

    private func verified(_ targets: [String: VerifiedTarget]) {
        verifiedTargets = targets
        verifying = false
        rebuild(board.entries(now: asOf))
        if verifyWanted {
            verifyWanted = false
            verifyTargets(board.entries(now: asOf))
        }
    }

    private func isHerdr(_ input: AgentInput) -> Bool {
        if case .herdr = input { true } else { false }
    }

    /// Looks for conversations that aren't open (any listed session is), off the main thread.
    private func refreshRecent(_ entries: [AgentBoard.Entry], now: Date) {
        if let fixedRecent {
            if recent != fixedRecent { recent = fixedRecent }
            recentLoaded = true
            return
        }
        guard !scanning else { scanWanted = true; return }
        scanning = true
        let open = Set(entries.compactMap { $0.agent.session?.lowercased() })
        var snapshot = scanner
        let home = home(), scratch = scratch
        Task.detached(priority: .utility) { [weak self] in
            let found = snapshot.list(home: home, excluding: open, now: now, scratch: scratch)
            await self?.scanned(snapshot, found)
        }
    }

    private func scanned(_ updated: RecentConversations, _ found: [RecentConversation]) {
        scanner = updated
        scanning = false
        recentLoaded = true
        if found != recent { recent = found }
        if scanWanted {
            scanWanted = false
            refresh()
        }
    }

    /// Opens it, unless it was opened a moment ago and the row is only still here because the session hasn't reached
    /// the board yet: that would start a second terminal on the same transcript.
    func resume(_ conversation: RecentConversation, now: Date = .now) {
        opening = opening.filter { now.timeIntervalSince($0.value) < Self.openingWindow }
        guard opening[conversation.id] == nil else { return }
        opening[conversation.id] = now
        onResume(conversation)
    }

    /// Opens the message field under a row that takes input, closing any other.
    func compose(_ row: AgentRow) {
        guard row.acceptsInput else { return }
        composing = row.id
    }

    func cancelCompose() {
        composing = nil
    }

    /// Closes the field of that row only: a row whose field is scrolled out of the list drops it, and the notch must not stay
    /// open for a field nobody can see.
    func cancelCompose(row id: String) {
        if composing == id { composing = nil }
    }

    /// Sends the message to the session, then Return. False when nothing was sent: the text is empty or the session no longer
    /// takes input.
    @discardableResult
    func send(message: String, to row: AgentRow) -> Bool {
        guard let text = AgentSend.message(message) else { return false }
        return deliver(text, submit: true, to: row)
    }

    /// Types the paths of the dropped files into the session, without Return. False when nothing was sent.
    @discardableResult
    func send(files urls: [URL], to row: AgentRow) -> Bool {
        guard let text = AgentSend.paths(urls) else { return false }
        return deliver(text, submit: false, to: row)
    }

    /// Checks the session as it is now, not as the row was drawn, and sends off the main thread, after looking once more at where its
    /// process runs.
    private func deliver(_ text: String, submit: Bool, to row: AgentRow) -> Bool {
        guard let current = rows.first(where: { $0.id == row.id }), current.acceptsInput, let input = current.input else { return false }
        notes[row.id] = nil
        guard let steps = AgentSend.steps(input, text: text, submit: submit, clis: clis()) else {
            note(Self.failure, for: row.id)
            return true
        }
        let sender = sender, targets = targets, pid = current.pid, id = row.id
        let others = Set(board.entries(now: asOf).compactMap { $0.agent.pid })
        Task.detached(priority: .userInitiated) { [weak self] in
            let sent = targets.hosted(input, pid: pid, others: others) && sender.run(steps)
            await self?.sent(sent, id)
        }
        return true
    }

    /// A send that failed leaves a note, and the target is verified again: the session may be gone, and its bubble with it.
    private func sent(_ sent: Bool, _ id: String) {
        guard !sent else { return }
        note(Self.failure, for: id)
        verifyTargets(board.entries(now: asOf))
    }

    private static var failure: String { String(localized: "Couldn't send to this session") }

    private func note(_ text: String, for id: String) {
        notes[id] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteDuration) { [weak self] in
            MainActor.assumeIsolated { if self?.notes[id] == text { self?.notes[id] = nil } }
        }
    }

    /// How long the note under a row stays.
    static let noteDuration: TimeInterval = 6

    private func checkConnected() -> Bool {
        if let isConnected { return isConnected() }
        return NotifyIntegration.$homeOverride.withValue(home()) { NotifyIntegration.claudeCode.isInstalled || NotifyIntegration.codex.isInstalled }
    }

    /// Whether the tab says it has nothing: no session is listed and no recent conversation turned up.
    var showsEmptyMessage: Bool { rows.isEmpty && recent.isEmpty && recentLoaded }

    /// What the tab says when no session is listed.
    var emptyMessage: String {
        connected ? String(localized: "No sessions used in the last 3 hours")
                  : String(localized: "Connect Claude Code and Codex in Settings › Alerts to see their sessions here")
    }

    private func rebuild(_ entries: [AgentBoard.Entry]) {
        let next = AgentRow.sorted(AgentRow.sharingTerminals(entries.map { entry in
            AgentRow(entry, transcript: fixed[entry.key] ?? AgentRow.transcriptKey(entry.agent).flatMap(transcripts.transcript),
                     inputVerified: entry.agent.input.map { verifiedTargets[entry.key] == VerifiedTarget(input: $0, pid: entry.agent.pid) } ?? false)
        }))
        if next != rows { rows = next }
        // The field closes with its row, or when the session starts waiting on a prompt: typing could answer it.
        if let composing, !rows.contains(where: { $0.id == composing && $0.acceptsInput }) { self.composing = nil }
        let kept = notes.filter { id, _ in rows.contains { $0.id == id } }
        if kept.count != notes.count { notes = kept }
    }
}

struct AgentsTab: View {
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        Group {
            if model.rows.isEmpty && model.recent.isEmpty {
                Text(verbatim: model.showsEmptyMessage ? model.emptyMessage : "")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The times count on from the minute they were drawn.
                TimelineView(.everyMinute) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(model.rows) { AgentRowView(row: $0, now: context.date, model: model) }
                            if !model.recent.isEmpty {
                                Text("Recent")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.top, model.rows.isEmpty ? 0 : 4)
                                ForEach(model.recent) { conversation in
                                    RecentRowView(conversation: conversation, now: context.date) { model.resume(conversation) }
                                }
                            }
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
    @ObservedObject var model: AgentsTabModel
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The tap goes to the terminal; the message field below it is clicked for typing, not for that.
            content
                .opacity(row.state == .idle ? 0.6 : 1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.cancelCompose()
                    row.target?.perform()
                }
            if model.composing == row.id {
                AgentComposer(row: row, model: model)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .surface(RoundedRectangle(cornerRadius: 10), opacity: (hovering && row.target != nil) || dropTargeted ? 0.14 : 0.08)
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5) }
        }
        .onHover { hovering = $0 }
        // Only a session that takes input accepts files; otherwise the drop isn't taken at all.
        .onDrop(of: row.acceptsInput ? [.fileURL] : [], isTargeted: $dropTargeted) { providers in
            ShelfSharing.loadURLs(from: providers) { model.send(files: $0, to: row) }
            return true
        }
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
                    if row.offersInput && (hovering || model.composing == row.id) { sendButton }
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
                if let note = model.notes[row.id] {
                    Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }

    /// Opens the message field; not usable while a prompt waits for its answer.
    private var sendButton: some View {
        Button { model.compose(row) } label: {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(row.acceptsInput ? 0.7 : 0.25))
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.acceptsInput)
        .help(row.inputBlocked ? Text("Answer the prompt first") : Text("Send a message"))
    }
}

/// The one-line field under a row: Return sends the message and closes it. Escape (see the notch's key monitor) and losing the
/// keyboard focus close it without sending.
private struct AgentComposer: View {
    let row: AgentRow
    @ObservedObject var model: AgentsTabModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Send a message", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($focused)
            .onSubmit { if model.send(message: text, to: row) { model.cancelCompose() } }
            .padding(.horizontal, 8).frame(height: 24)
            .surface(RoundedRectangle(cornerRadius: 6), opacity: 0.1)
            .onAppear { focused = true }
            .onDisappear { model.cancelCompose(row: row.id) }
            .onChange(of: focused) { _, isFocused in if !isFocused { model.cancelCompose() } }
    }
}

private struct RecentRowView: View {
    let conversation: RecentConversation
    let now: Date
    let resume: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(.white.opacity(0.45))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: conversation.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(verbatim: conversation.details(now: now).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(0.65)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .surface(RoundedRectangle(cornerRadius: 10), opacity: hovering ? 0.14 : 0.06)
        .contentShape(Rectangle())
        .onTapGesture(perform: resume)
        .onHover { hovering = $0 }
        .help(Text(verbatim: conversation.cwd))
    }
}
