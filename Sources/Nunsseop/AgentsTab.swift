import Combine
import SwiftUI

/// One coding agent session in the Agents tab.
struct AgentRow: Identifiable, Equatable {
    /// Where a click goes when the session's terminal isn't known to be verified: the herdr pane, else the terminal app the session
    /// runs in (the hook's, else the one found above its process). A verified terminal is gone to by its tab or pane instead (see
    /// `AgentFocus.plan`).
    enum Target: Equatable {
        case herdr(pane: String, socket: String)
        case app(String)
    }

    let id: String
    let tool: String
    let state: AgentBoard.State
    let finished: Bool
    /// The background tasks still running after the turn's end, for the "Background · 3 tasks" chip.
    let background: Int
    let since: Date?
    let path: String?
    let model: String?
    let tokens: Int?
    let mode: AgentMode?
    let name: String?
    /// What the agent did last in its turn, and the files the turn changed, from its transcript.
    let activity: AgentActivity?
    let edits: [AgentActivity.Edit]
    /// The program that runs it for the tool, as the source says (Paseo).
    let host: String?
    let target: Target?
    /// Where the terminal takes text from outside, if it has an API for that, as the hook named it: see `offersInput`.
    let input: AgentInput?
    /// The tool's process, which `input` is checked against.
    let pid: Int32?
    /// Whether `AgentTargetCheck` found the session's process in the terminal `input` names.
    let inputVerified: Bool
    /// Muxy itself lists the session (it has no process to check): its terminal is known for going to it, though not for typing into it.
    let listedByTerminal: Bool
    /// A prompt may be open in the terminal this row types into: the session's own, however long it has waited, or that of
    /// another listed session sharing the terminal (`claude -p` started from it, a Codex session it replaced).
    private(set) var promptOnTerminal: Bool
    /// Why the row offers no input, decided from what the board and the verification know; nil when it does (see `inputBlock`).
    private let notOffered: InputBlock?

    /// Why a session can't be sent a message, for the tooltip of its button.
    enum InputBlock: Equatable {
        /// A prompt or question may be open on its terminal; typing could answer it.
        case prompt
        /// It runs inside tmux, zellij or screen, which no input API reaches.
        case multiplexer
        /// Its terminal app is known (bundle id, or the name of its bundle) and has no input API Nunsseop supports.
        case unsupportedApp(String)
        /// No process to verify: its hook predates `X-Pid`, or it is a background session.
        case noProcess
        /// The terminal supports input, but the session couldn't be shown to be in it.
        case unconfirmed
        /// Muxy itself lists the session: its terminal is known, but with no process to check Nunsseop doesn't type into it.
        case listedOnly
        /// Ghostty has several tabs in the session's folder and nothing tells which is its own.
        case ambiguousTab
        /// macOS hasn't allowed Nunsseop to control the app (Automation), so the session's tab can't be looked for.
        case notAllowed(String)
        /// The check of its terminal hasn't covered the row yet; the reason may turn out to be none.
        case checking
        /// A Paseo agent that is working: its command line interrupts the turn to send, so it is sent to between turns.
        case paseoBusy
        /// A Paseo agent, and no `paseo` command line to send it through.
        case paseoNoCLI

        var message: String {
            switch self {
            case .prompt: String(localized: "Answer the prompt first")
            case .multiplexer: String(localized: "Can't send into tmux, zellij or screen")
            case .unsupportedApp(let app): String(localized: "\(AgentRow.appName(app)) doesn't let Nunsseop type into it")
            case .noProcess: String(localized: "Restart this session to send to it")
            case .unconfirmed: String(localized: "Couldn't confirm which terminal this session is in")
            case .listedOnly: String(localized: "Muxy lists this session, so Nunsseop can take you to it but not type into it")
            case .ambiguousTab: String(localized: "There are several Ghostty tabs in this folder, so Nunsseop can't tell which one")
            case .notAllowed(let app): TerminalScripts.notAllowedNote(app)
            case .checking: String(localized: "Checking…")
            case .paseoBusy: String(localized: "Paseo would interrupt its turn: message it once it is done")
            case .paseoNoCLI: String(localized: "Paseo's command line wasn't found, so Nunsseop can't send to this agent")
            }
        }
    }

    /// The terminals that have an input API (see `AgentInput`); the other apps a session can run in have none.
    static let inputApps: Set<String> = [TerminalScripts.terminalID, TerminalScripts.itermID, Muxy.bundleID, Cmux.bundleID,
                                         WezTerm.bundleID, Kitty.bundleID, TerminalScripts.ghosttyID, Orca.bundleID]

    /// An app's name for the tooltip: the installed app's own, else the last part of its bundle id; a name with a space or no dot is
    /// an app folder's (see `AgentTargetCheck.hostApp`) and stays whole. `installed` finds the name by bundle id.
    static func appName(_ bundleID: String, installed: (String) -> String? = { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
    }) -> String {
        if let name = installed(bundleID)?.replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards]), !name.isEmpty { return name }
        guard !bundleID.contains(" "), bundleID.contains(".") else { return bundleID }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// - multiplexed: the session's own environment says tmux, zellij or screen (for a hook that didn't).
    /// - hostApp: the app found above its process, for a hook that named none (see `AgentTargetCheck.hostApp`).
    /// - checked: whether a verification pass has covered the entry's key and process; until it has, a row with a process that
    ///   isn't sendable reads `.checking`, not a reason a pass may still overturn.
    /// - blockedBy: the reason the model found for a session whose terminal needed a look of its own (Ghostty's tabs).
    init(_ entry: AgentBoard.Entry, transcript: AgentTranscript?, inputVerified: Bool = false, multiplexed: Bool = false, hostApp: String? = nil,
         checked: Bool = true, blockedBy: InputBlock? = nil) {
        let agent = entry.agent
        id = entry.key
        tool = Self.toolName(agent.tool)
        state = agent.state
        finished = agent.finished
        background = agent.background
        since = agent.since
        path = [agent.cwd, transcript?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty }
        model = transcript?.model ?? agent.model
        tokens = transcript?.tokens
        mode = transcript?.mode
        name = agent.title ?? transcript?.name
        activity = transcript?.activity
        edits = transcript?.edits ?? []
        host = agent.host
        target = Self.target(for: agent) ?? Self.bundleID(hostApp).map(Target.app)
        input = agent.input
        pid = agent.pid
        self.inputVerified = inputVerified
        listedByTerminal = entry.source == MuxyActivityWatcher.source
        promptOnTerminal = agent.promptMayBeOpen
        // Only a hook session can be restarted, and only its hook names an app or a multiplexer; any other source (gjc, a herdr
        // pane without its socket) can only be unconfirmed.
        let hook = entry.source.hasPrefix("hooks:")
        if entry.source == Paseo.source {
            // Its agents have no terminal; what keeps one from taking a message is only the command line.
            notOffered = .paseoNoCLI
        } else if agent.inMultiplexer || multiplexed {
            notOffered = .multiplexer
        } else if !checked && agent.pid != nil {
            // The process environment may still say tmux, and the process tree may still name another app.
            notOffered = .checking
        } else if let blockedBy {
            notOffered = blockedBy
        } else if listedByTerminal {
            notOffered = .listedOnly
        } else if hook, let app = agent.app ?? hostApp, !Self.inputApps.contains(app) {
            notOffered = .unsupportedApp(app)
        } else {
            notOffered = hook && agent.pid == nil ? .noProcess : .unconfirmed
        }
    }

    /// Whether the row can be sent to and takes drops: its terminal has an input API and the session is in it. A herdr
    /// pane comes from herdr's own list; any other target is the hook's word, so it counts once it is verified.
    var offersInput: Bool {
        switch input {
        case nil: false
        case .herdr, .paseo: true
        case .muxy, .cmux, .terminalApp, .iterm, .wezterm, .kitty, .ghostty, .orca: inputVerified
        }
    }

    /// Whether the row is an agent of Paseo that can be sent to.
    var isPaseo: Bool { if case .paseo? = input { true } else { false } }

    /// Whether going to the session does anything: there is an app or pane to go to, or a verified terminal to select the session's tab in.
    var focusable: Bool { target != nil || offersInput }

    /// Whether text can be sent to the session now: its terminal has an input API and no prompt may be waiting there.
    var acceptsInput: Bool { offersInput && !promptOnTerminal && AgentSend.accepts(state: state, finished: finished) && !(isPaseo && state == .working) }

    /// Whether files can be dropped on the row: it takes input, and in a form that can be typed without being sent.
    var takesDrops: Bool { acceptsInput && !isPaseo }

    /// Its terminal takes input, but a prompt waits for the answer first.
    var inputBlocked: Bool { offersInput && !acceptsInput }

    /// Why the Message button is disabled for this row, nil when it works. A prompt only counts for a row that could be typed into:
    /// answering it would not make any other row sendable.
    var inputBlock: InputBlock? { offersInput ? (acceptsInput ? nil : isPaseo && state == .working ? .paseoBusy : .prompt) : notOffered }

    /// The sentence that says it: the Message button's tooltip, and the footer's when the row is selected.
    var blockReason: String? { inputBlock?.message }

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

    /// The folder when a name is the title (unless it says the same), then the tool (unless it is the title) and the model. The
    /// state is the marker's, the mode the chip's, the context the meter's.
    var metaParts: [String] {
        var parts: [String] = []
        if let name, let folder, folder.caseInsensitiveCompare(name) != .orderedSame { parts.append(folder) }
        if name != nil || folder != nil { parts.append(tool) }
        if let host { parts.append(host) }
        if let model { parts.append(AgentTranscript.modelLabel(model)) }
        return parts
    }

    var meta: String { metaParts.joined(separator: " · ") }

    /// "Background · 3 tasks" while the turn is over and background tasks keep the session working.
    var backgroundChip: String? {
        guard state == .working, background > 0 else { return nil }
        return background == 1 ? String(localized: "Background · \(background) task") : String(localized: "Background · \(background) tasks")
    }

    /// The chip after the meta when the mode isn't the default; `warns` when nothing asks before it acts.
    var modeChip: (text: String, warns: Bool)? { mode?.label.map { ($0, mode?.warns ?? false) } }

    /// The window a model's context is measured against: 1M for an id marked "[1m]", else 200k. A count above 200k can only be a
    /// larger window, so that is 1M too; the ids don't say anything finer.
    static func contextWindow(model: String?, tokens: Int?) -> Int {
        model?.lowercased().contains("[1m]") == true || (tokens ?? 0) > 200_000 ? 1_000_000 : 200_000
    }

    /// How full the context is, 0...1; nil when the transcript has no count.
    var contextFraction: Double? {
        tokens.map { min(1, max(0, Double($0) / Double(Self.contextWindow(model: model, tokens: $0)))) }
    }

    /// "142k".
    var tokensLabel: String? { tokens.map(AgentTranscript.tokensLabel) }

    /// What the meter and the label say together, for VoiceOver and the tooltip.
    var contextDescription: String? {
        tokens.map { String(localized: "Context \(AgentTranscript.tokensLabel($0)) of \(AgentTranscript.tokensLabel(Self.contextWindow(model: model, tokens: $0)))") }
    }

    /// A session that asks for an answer: its row opens to say so. A finished hand ("Your turn") stays one line.
    var asksForAnswer: Bool { state == .waiting && !finished }
    /// The last step shows under a row at work or done with its turn; one that asks shows its prompt instead.
    var showsActivity: Bool { activity != nil && state != .idle && !asksForAnswer }

    /// A path inside the session's folder, from there; any other as it is.
    func shortPath(_ path: String) -> String {
        guard let folder = self.path, path.hasPrefix(folder + "/") else { return path }
        return String(path.dropFirst(folder.count + 1))
    }

    /// What the opened row says is being asked. Nothing on the permission board names its session (only a folder), so it is the
    /// generic sentence.
    var waitingPrompt: String? { asksForAnswer ? String(localized: "Waiting for your answer") : nil }

    /// What the state marker says, for VoiceOver and its tooltip.
    var stateLabel: String {
        switch state {
        case .waiting: finished ? String(localized: "Your turn") : String(localized: "Needs input")
        case .working: String(localized: "Working")
        case .idle: String(localized: "Idle")
        }
    }

    /// Why the Go to terminal button is disabled, nil when it works.
    var terminalBlock: String? { focusable ? nil : InputBlock.unconfirmed.message }

    /// "1 waiting · 3 working · 1 idle", the parts that are zero left out. The words don't change with the count in any language
    /// (the de, es and fr ones are adjectives or phrases that don't agree).
    static func summary(_ rows: [AgentRow]) -> String {
        let counts = [rows.filter { $0.state == .waiting }.count, rows.filter { $0.state == .working }.count, rows.filter { $0.state == .idle }.count]
        let words = [String(localized: "\(counts[0]) waiting"), String(localized: "\(counts[1]) working"), String(localized: "\(counts[2]) idle")]
        return zip(counts, words).filter { $0.0 > 0 }.map(\.1).joined(separator: " · ")
    }

    /// The tool's name as it presents itself; herdr's own name for an agent that isn't one of ours.
    static func toolName(_ raw: String?) -> String {
        if let kind = kind(raw) { return kind.displayName }
        return raw.flatMap { $0.isEmpty ? nil : $0 } ?? "herdr"
    }

    static func kind(_ tool: String?) -> AgentKind? { AgentKind(tool: tool) }

    /// Where the transcript is looked for; herdr gives the session id of the agent in a pane.
    static func transcriptKey(_ agent: AgentBoard.Agent) -> AgentTranscripts.Key? {
        guard let kind = kind(agent.tool), kind.hasTranscript, let session = agent.session else { return nil }
        return AgentTranscripts.Key(kind: kind, session: session)
    }

    /// The app found above a process, if it is a bundle id (`AgentTargetCheck.hostApp` gives an app folder's name when the bundle is unreadable).
    static func bundleID(_ app: String?) -> String? {
        guard let app, app.contains("."), !app.contains(" ") else { return nil }
        return app
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
        case ..<60: return String(localized: "<1m")
        case ..<3_600: return String(localized: "\(Int(seconds / 60))m")
        case ..<86_400: return String(localized: "\(Int(seconds / 3_600))h")
        default: return String(localized: "\(Int(seconds / 86_400))d")
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
    @Published private(set) var rows: [AgentRow] = [] { didSet { pruneSelection(); follow() } }
    /// Conversations that aren't open, to pick up again; listed when no session is.
    @Published private(set) var recent: [RecentConversation] = [] { didSet { pruneSelection() } }
    /// Whether the first look for them is done; until then an empty list doesn't mean there are none.
    @Published private(set) var recentLoaded = false
    /// Whether a tool that reports its sessions is connected, which tells an empty tab from one waiting for a connection.
    @Published private(set) var connected = false
    /// The row with the cursor, by `AgentRow.id`; with no rows, the recent conversation with it, by `RecentConversation.id`. One at a
    /// time; ↑↓ move it, a click sets it.
    @Published private(set) var selected: String?
    /// The row whose message field is open, by `AgentRow.id`: the field has the keyboard, and the notch stays open while it does.
    @Published private(set) var composing: String?
    /// The row whose turn's changes show in place of the list, and which change.
    @Published private(set) var diffing: DiffFocus?

    struct DiffFocus: Equatable {
        let id: String
        var index: Int
    }

    /// How often the transcripts of sessions at work are looked at while the tab shows: the hooks say nothing between a prompt
    /// and the turn's end.
    static let followInterval: TimeInterval = 2
    private var following: Timer?
    /// A short note under a row whose message or files didn't go out, by `AgentRow.id`.
    @Published private(set) var notes: [String: String] = [:]
    /// Under the recent conversations: macOS didn't let Nunsseop open one in the terminal chosen (see `Resume.notAllowedNotification`).
    @Published private(set) var resumeNote: String?
    private var denial: AnyCancellable?
    var isShowing = false {
        didSet {
            if !isShowing { composing = nil; selected = nil; diffing = nil }
            follow()
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
    // Vars only for `--demo-agents`, which swaps in fakes (see `AgentBoard.demoSender`).
    private var sender: AgentSender
    private var clis: () -> TerminalCLIs
    private var targets: AgentTargetCheck
    private let environments: ProcessEnvironment
    private let scripts: AppleScriptRunner
    private let focuser: AgentFocuser
    private var transcripts = AgentTranscripts()
    private(set) var loading = false
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
    /// The targets found in the own environment of the sessions whose hook named none, by `Entry.key`, for the process they were
    /// found for; they take the place of the hook's until it names one.
    private var derivedTargets: [String: VerifiedTarget] = [:]
    /// What `ProcessEnvironment` read of each such session's process, by pid. A process's environment doesn't change, so it is read
    /// once; only the pids on the board are kept.
    private var environmentCache: [Int32: [String: String]] = [:]
    /// The sessions whose process runs under Ghostty itself with no other terminal between, by `Entry.key`, for the process, and the
    /// terminals Ghostty listed in the same pass (nil when no session is in it). The tab of each is worked out from these in `rebuild`,
    /// when its folder and name are known.
    private var ghosttyHosted: [String: Int32] = [:]
    private var ghosttyListing: GhosttyListing?
    /// The terminal each row that can be sent to in Ghostty was resolved to, by `Entry.key`; what a send finds the tab again by.
    private var ghosttyPicks: [String: GhosttyPick] = [:]
    /// The handle Orca's tool gave the pane of each row verified in Orca, by `Entry.key`: found in the same pass as the proof.
    private var orcaPicks: [String: OrcaPick] = [:]
    /// The app found above the process of each session whose hook named none, by `Entry.key`; for the tooltip of a row that can't be typed into.
    private var hostApps: [String: String] = [:]
    /// The entries a verification pass has covered: `Entry.key` and process, see `checkedKey`. A row outside it is still being checked.
    private var checked: Set<String> = []
    private var scanner = RecentConversations()
    private var paseoScanner = PaseoScanner()
    private var scanning = false
    private var scanWanted = false
    private var observer: AnyCancellable?
    /// When each conversation was last clicked, which is how a repeat click is told from a first one.
    private var opening: [String: Date] = [:]
    /// How long a click on the same conversation is ignored: the terminal takes a while to start, cmux up to 10 s.
    static let openingWindow: TimeInterval = 15

    /// - isConnected: whether a tool is connected; by default, whether the tools' settings or files under `home` say so.
    /// - scratch: folders whose conversations are left out.
    /// - onResume: what clicking a recent conversation does; by default, opens it in the terminal chosen in Settings.
    /// - sender: what puts text into a terminal; tests give it one that records instead.
    /// - clis: where the terminals' command-line tools are, looked up on every send.
    /// - targets: how a session's terminal is verified; tests give it a made-up process tree.
    /// - environments: how the environment of a session's process is read; tests give it made-up ones.
    /// - scripts: what looks at Ghostty's tabs (the sends go through `sender`); tests give it one that answers from a made-up list.
    /// - focuser: what a click on a row does to the terminals; by default the real tools, with the AppleScript steps through `scripts`.
    init(board: AgentBoard, home: @escaping () -> URL = { NotifyIntegration.home }, isConnected: (() -> Bool)? = nil,
         scratch: [String] = RecentConversations.scratch, onResume: @escaping (RecentConversation) -> Void = Resume.inChosenTerminal,
         sender: AgentSender = .live, clis: @escaping () -> TerminalCLIs = { .live }, targets: AgentTargetCheck = .live,
         environments: ProcessEnvironment = .live, scripts: AppleScriptRunner = .live, focuser: AgentFocuser? = nil) {
        self.board = board
        self.home = home
        self.isConnected = isConnected
        self.onResume = onResume
        self.scratch = scratch
        self.sender = sender
        self.clis = clis
        self.targets = targets
        self.environments = environments
        self.scripts = scripts
        self.focuser = focuser ?? .live(scripts: scripts)
        connected = checkConnected()
        #if DEBUG
        if CommandLine.arguments.contains("--demo-agents") {
            fixed = AgentBoard.demoTranscripts
            fixedRecent = AgentBoard.demoRecent()
            self.sender = AgentBoard.demoSender
            self.clis = { AgentBoard.demoCLIs }
            self.targets = AgentBoard.demoTargets
        }
        #endif
        observer = board.$revision.sink { [weak self] _ in
            MainActor.assumeIsolated { if self?.isShowing == true { self?.refresh() } }
        }
        denial = NotificationCenter.default.publisher(for: Resume.notAllowedNotification).sink { [weak self] note in
            let app = note.userInfo?["bundleID"] as? String ?? ""
            MainActor.assumeIsolated { self?.resumeNotAllowed(app) }
        }
    }

    /// Says where to allow the terminal, for as long as a note stays.
    func resumeNotAllowed(_ app: String) {
        showResumeNote(TerminalScripts.notAllowedNote(app))
    }

    private func showResumeNote(_ text: String) {
        resumeNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + noteDuration) { [weak self] in
            MainActor.assumeIsolated { if self?.resumeNote == text { self?.resumeNote = nil } }
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

    /// Looks at the transcripts every `followInterval` while the tab shows a session at work.
    private func follow() {
        let wanted = isShowing && rows.contains { $0.state == .working }
        guard wanted != (following != nil) else { return }
        following?.invalidate()
        following = nil
        guard wanted else { return }
        let timer = Timer(timeInterval: Self.followInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readTranscripts() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        following = timer
    }

    /// The transcripts only, for the last steps: the terminals and recent conversations stay as the last refresh left them.
    private func readTranscripts() {
        guard !loading else { return }
        let entries = board.entries(now: .now)
        let keys = Set(entries.compactMap { fixed[$0.key] == nil ? AgentRow.transcriptKey($0.agent) : nil })
        guard !keys.isEmpty else { return }
        asOf = .now
        loading = true
        let snapshot = transcripts, home = home()
        Task.detached(priority: .utility) { [weak self] in
            var updated = snapshot
            updated.refresh(keys, home: home)
            await self?.loaded(updated)
        }
    }

    /// Shows the changes of the row's turn, from the latest.
    func showDiff(_ row: AgentRow) {
        guard !row.edits.isEmpty else { return }
        diffing = DiffFocus(id: row.id, index: row.edits.count - 1)
    }

    func closeDiff() { diffing = nil }

    /// The change before (-1) or after (1) the one shown. True when there was one.
    @discardableResult
    func stepDiff(_ by: Int) -> Bool {
        guard var focus = diffing, let row = rows.first(where: { $0.id == focus.id }), row.edits.indices.contains(focus.index + by) else { return false }
        focus.index += by
        diffing = focus
        return true
    }

    private func loaded(_ updated: AgentTranscripts) {
        transcripts = updated
        loading = false
        rebuild(board.entries(now: asOf))
        if changedWhileLoading {
            changedWhileLoading = false
            // For the moment the repeated refresh was asked for: the real clock would not be the one a caller gave.
            refresh(now: asOf)
        }
    }

    private static func checkedKey(_ key: String, _ pid: Int32) -> String { "\(key)|\(pid)" }

    /// Checks, off the main thread, that each session's process runs in the terminal its hook named (see `AgentTargetCheck`); until
    /// then, or when it doesn't, the row offers no input. Muxy's session list is read once for all of them. A session whose hook named
    /// none (it started before the hook sent the terminal's variables) is looked at through its process's own environment.
    private func verifyTargets(_ entries: [AgentBoard.Entry]) {
        let named = entries.compactMap { entry -> (key: String, target: VerifiedTarget)? in
            guard let input = entry.agent.input, !isListed(input) else { return nil }
            return (entry.key, VerifiedTarget(input: input, pid: entry.agent.pid))
        }
        let unnamed = entries.compactMap { entry -> (key: String, pid: Int32, app: String?)? in
            guard entry.agent.input == nil, let pid = entry.agent.pid else { return nil }
            return (entry.key, pid, entry.agent.app)
        }
        guard !named.isEmpty || !unnamed.isEmpty else {
            if !verifiedTargets.isEmpty { verifiedTargets = [:] }
            if !derivedTargets.isEmpty { derivedTargets = [:] }
            if !environmentCache.isEmpty { environmentCache = [:] }
            if !hostApps.isEmpty { hostApps = [:] }
            if !ghosttyHosted.isEmpty { ghosttyHosted = [:] }
            if !orcaPicks.isEmpty { orcaPicks = [:] }
            ghosttyListing = nil
            if !checked.isEmpty { checked = [] }
            return
        }
        guard !verifying else { verifyWanted = true; return }
        verifying = true
        let tools = clis()
        let targets = targets, environments = environments, muxy = tools.muxy, orca = tools.orca, others = Set(entries.compactMap { $0.agent.pid })
        let pids = Set(unnamed.map(\.pid))
        let covered = Set(entries.compactMap { entry in entry.agent.pid.map { Self.checkedKey(entry.key, $0) } })
        let unplaced = entries.compactMap { entry -> (key: String, pid: Int32)? in
            guard entry.agent.app == nil, entry.agent.pane == nil, let pid = entry.agent.pid else { return nil }
            return (entry.key, pid)
        }
        // A session that may be in Ghostty: no input of its own, no multiplexer or herdr pane, and no other app named.
        let unlisted = entries.compactMap { entry -> (key: String, pid: Int32)? in
            let agent = entry.agent
            guard agent.input == nil, !agent.inMultiplexer, agent.pane == nil, let pid = agent.pid,
                  agent.app == nil || agent.app == TerminalScripts.ghosttyID else { return nil }
            return (entry.key, pid)
        }
        let scripts = scripts
        let cached = environmentCache.filter { pids.contains($0.key) }
        Task.detached(priority: .utility) { [weak self] in
            var cache = cached
            var derived: [String: VerifiedTarget] = [:]
            for session in unnamed {
                let variables = cache[session.pid] ?? environments.variables(of: session.pid)
                cache[session.pid] = variables
                let found = AgentHook.input(environment: variables, app: session.app, tty: { targets.processes.lookup(session.pid)?.tty },
                                            hosted: { targets.hosted($0, pid: session.pid) })
                if let found { derived[session.key] = VerifiedTarget(input: found, pid: session.pid) }
            }
            let candidates = named + derived.map { (key: $0.key, target: $0.value) }
            let wantsList = candidates.contains { if case .muxy = $0.target.input { true } else { false } }
            let sessions = wantsList ? targets.muxySessions(cli: muxy) : nil
            // Orca's panes are listed once for all of them, and only if one session says it is in Orca.
            let wantsOrca = candidates.contains { if case .orca = $0.target.input { true } else { false } }
            let panes = wantsOrca ? targets.orcaPanes(cli: orca) : nil
            let verified = candidates.filter { targets.verified($0.target.input, pid: $0.target.pid, muxySessions: sessions, orcaPanes: panes, others: others) }
            var picks: [String: OrcaPick] = [:]
            for session in verified {
                if case .orca(let key) = session.target.input, let handle = panes?[key] { picks[session.key] = OrcaPick(paneKey: key, handle: handle) }
            }
            var hosts: [String: String] = [:]
            for session in unplaced { hosts[session.key] = targets.hostApp(pid: session.pid) }
            let taken = Set(verified.map(\.key))
            // Ghostty has no id a shell could report: the process tree is the proof, and its tabs are listed once for all of them.
            var inGhostty: [String: Int32] = [:]
            for session in unlisted where !taken.contains(session.key) {
                let variables = cache[session.pid] ?? environments.variables(of: session.pid)
                cache[session.pid] = variables
                guard !AgentHook.inMultiplexer(environment: variables), variables["HERDR_PANE_ID"]?.isEmpty != false,
                      targets.hosted(.ghostty(cwd: "", name: nil), pid: session.pid, others: others) else { continue }
                inGhostty[session.key] = session.pid
            }
            let listing = inGhostty.isEmpty ? nil : Ghostty.list(scripts: scripts)
            await self?.verified(Dictionary(uniqueKeysWithValues: verified.map { ($0.key, $0.target) }), derived: derived, environments: cache, hosts: hosts, covered: covered,
                                 ghostty: (inGhostty, listing), orca: picks)
        }
    }

    private func verified(_ targets: [String: VerifiedTarget], derived: [String: VerifiedTarget], environments: [Int32: [String: String]],
                          hosts: [String: String], covered: Set<String>, ghostty: (hosted: [String: Int32], listing: GhosttyListing?),
                          orca: [String: OrcaPick]) {
        checked = covered
        orcaPicks = orca
        ghosttyHosted = ghostty.hosted
        ghosttyListing = ghostty.listing
        verifiedTargets = targets
        hostApps = hosts
        derivedTargets = derived
        environmentCache = environments
        verifying = false
        rebuild(board.entries(now: asOf))
        if verifyWanted {
            verifyWanted = false
            verifyTargets(board.entries(now: asOf))
        }
    }

    /// Whether the input comes from its source's own list (a herdr pane, a Paseo agent), which needs no check of a process.
    private func isListed(_ input: AgentInput) -> Bool {
        switch input {
        case .herdr, .paseo: true
        default: false
        }
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
        let openAgents = Set(entries.filter { $0.source == Paseo.source }.map(\.id))
        var snapshot = scanner, paseo = paseoScanner
        let home = home(), scratch = scratch
        Task.detached(priority: .utility) { [weak self] in
            let found = snapshot.list(home: home, excluding: open, now: now, scratch: scratch)
            // Paseo's agents are looked for only where Paseo has been used.
            let daemon = PaseoDaemon.read(home: home)
            let recents = Paseo.isPresent(home: home, appInstalled: { false })
                ? PaseoRecents.list(paseo.scan(home: home, now: now), excluding: open.union(openAgents),
                                    server: daemon?.serverID ?? Paseo.storedServerID(home: home), daemonUp: daemon != nil && daemon?.starting != true,
                                    now: now, scratch: scratch) : []
            await self?.scanned(snapshot, paseo, PaseoRecents.merged(found, recents))
        }
    }

    private func scanned(_ updated: RecentConversations, _ paseo: PaseoScanner, _ found: [RecentConversation]) {
        scanner = updated
        paseoScanner = paseo
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
        if let paseo = conversation.paseo { return resumeInPaseo(paseo, id: conversation.id) }
        onResume(conversation)
    }

    /// Brings an agent of Paseo back through Paseo's own command line and shows it in the app, off the main thread. A failure leaves a
    /// note and lets the conversation be clicked again.
    private func resumeInPaseo(_ paseo: PaseoResume, id: String) {
        guard let steps = paseo.steps(cli: clis().paseo) else { return resumeFailed(id) }
        let sender = sender, needsDaemon = paseo.needsDaemon
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = sender.run(steps)
            await self?.resumeEnded(outcome, id, needsDaemon: needsDaemon)
        }
    }

    /// An archived agent with the daemon down only had the app started: the click is for again once the daemon is up.
    private func resumeEnded(_ outcome: SendOutcome, _ id: String, needsDaemon: Bool = false) {
        if outcome != .sent { return resumeFailed(id) }
        guard needsDaemon else { return }
        opening[id] = nil
        showResumeNote(String(localized: "Paseo is starting: click this conversation again in a moment"))
    }

    private func resumeFailed(_ id: String) {
        opening[id] = nil
        showResumeNote(String(localized: "Couldn't open this conversation in Paseo"))
    }

    /// A click selects the row, and ends typing to another one; a double click also goes to its terminal.
    func click(_ row: AgentRow, count: Int = 1) {
        select(row.id)
        if count >= 2 { focus(row) }
    }

    /// Puts the cursor on a row or recent conversation (nil: none). Typing stays with its own row.
    func select(_ id: String?) {
        if composing != id { composing = nil }
        selected = id
    }

    /// Opens the message field for a row that takes input now, closing any other; a row that doesn't is only selected, so the footer
    /// says why.
    func compose(_ row: AgentRow) {
        guard let current = rows.first(where: { $0.id == row.id }) else { return }
        guard current.acceptsInput else { return select(current.id) }
        selected = current.id
        composing = current.id
    }

    /// Escape: the field lets go of the keyboard and goes.
    func cancelCompose() {
        composing = nil
    }

    /// Closes the field of that row only: a row whose field is scrolled out of the list drops it, and the notch must not stay
    /// open for a field nobody can see.
    func cancelCompose(row id: String) {
        if composing == id { composing = nil }
    }

    /// Return in the row's field: sends the text to that row only (see `send(message:to:)`) and closes the field. False when
    /// nothing was sent, and the field stays.
    @discardableResult
    func submit(message: String, to row: AgentRow) -> Bool {
        guard send(message: message, to: row) else { return false }
        cancelCompose(row: row.id)
        return true
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
        if row.input?.takesFiles == false {
            note(String(localized: "Terminal can't take text without running it"), for: row.id)
            return false
        }
        return deliver(text, submit: false, to: row)
    }

    /// Goes to the session: its tab or pane when its terminal is verified, else its app (see `AgentFocus.plan`). The calls run off the
    /// main thread, after looking once more at where the session's process runs; a terminal that no longer holds it is not focused.
    func focus(_ row: AgentRow) {
        guard let current = rows.first(where: { $0.id == row.id }) else { return }
        notes[row.id] = nil
        switch AgentFocus.plan(for: current, clis: clis(), ghostty: ghosttyPicks[row.id], orca: orcaPicks[row.id]) {
        case .herdr(let pane, let socket): focuser.herdr(pane, socket)
        case .app(let app): focuser.activate(app)
        case .nothing: break
        case .terminal(let steps, let app):
            guard let input = current.input else { return }
            let focuser = focuser, targets = targets, pid = current.pid, id = row.id, listed = current.listedByTerminal
            let others = Set(board.entries(now: asOf).compactMap { $0.agent.pid })
            Task.detached(priority: .userInitiated) { [weak self] in
                let outcome = listed || targets.hosted(input, pid: pid, others: others) ? focuser.run(steps) : .failed
                await self?.focused(outcome, id, app)
            }
        }
    }

    /// The session that has been waiting for you longest; one that doesn't say since when comes last.
    static func longestWaiting(in rows: [AgentRow]) -> AgentRow? {
        rows.filter { $0.state == .waiting }.min { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// Goes to the session that has waited longest, as a double click on its row does. False when none waits. With the tab not showing
    /// nothing keeps the rows current, so they are made again first.
    @discardableResult
    func focusLongestWaiting(now: Date = .now) -> Bool {
        if !isShowing {
            asOf = now
            rebuild(board.entries(now: now))
        }
        guard let row = Self.longestWaiting(in: rows) else { return false }
        focus(row)
        return true
    }

    /// The app comes forward whatever the calls came to. One that failed means the session may be gone, so its target is verified again;
    /// one macOS refused leaves the note that says where to allow it.
    private func focused(_ outcome: SendOutcome, _ id: String, _ app: String) {
        focuser.activate(app)
        switch outcome {
        case .sent: return
        case .failed: verifyTargets(board.entries(now: asOf))
        case .notAllowed(let denied): note(TerminalScripts.notAllowedNote(denied), for: id)
        }
    }

    /// Checks the session as it is now, not as the row was drawn, and sends off the main thread, after looking once more at where its
    /// process runs.
    private func deliver(_ text: String, submit: Bool, to row: AgentRow) -> Bool {
        guard let current = rows.first(where: { $0.id == row.id }), current.acceptsInput, let input = current.input else { return false }
        notes[row.id] = nil
        guard let steps = AgentSend.steps(input, text: text, submit: submit, clis: clis(), ghostty: ghosttyPicks[row.id], orca: orcaPicks[row.id]) else {
            note(Self.failure, for: row.id)
            return true
        }
        let sender = sender, targets = targets, pid = current.pid, id = row.id
        let others = Set(board.entries(now: asOf).compactMap { $0.agent.pid })
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = targets.hosted(input, pid: pid, others: others) ? sender.run(steps) : .failed
            await self?.sent(outcome, id)
        }
        return true
    }

    /// A send that failed leaves a note, and the target is verified again: the session may be gone, and its Message button with it.
    private func sent(_ outcome: SendOutcome, _ id: String) {
        switch outcome {
        case .sent: return
        case .failed: note(Self.failure, for: id)
        // Not a gone session: the target stays, and the note says where to allow it.
        case .notAllowed(let app): return note(TerminalScripts.notAllowedNote(app), for: id)
        }
        verifyTargets(board.entries(now: asOf))
    }

    private static var failure: String { String(localized: "Couldn't send to this session") }

    private func note(_ text: String, for id: String) {
        notes[id] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + noteDuration) { [weak self] in
            MainActor.assumeIsolated { if self?.notes[id] == text { self?.notes[id] = nil } }
        }
    }

    /// How long a note stays (the one under a row, and the one about a conversation that would not open); tests make it long, or a note
    /// that came and went while the main actor was busy could not be waited for.
    var noteDuration: TimeInterval = 6

    private func checkConnected() -> Bool {
        if let isConnected { return isConnected() }
        // gjc needs no connection: its sessions are read from its own files.
        return NotifyIntegration.$homeOverride.withValue(home()) {
            NotifyIntegration.reportingSessions.contains(where: \.isInstalled)
                || FileManager.default.fileExists(atPath: home().appendingPathComponent(".gjc").path)
                || Paseo.isPresent(home: home(), appInstalled: { false })
        }
    }

    /// Recent conversations are listed only when no session is: with sessions open they are noise next to them.
    var showsRecent: Bool { rows.isEmpty && !recent.isEmpty }

    /// What ↑↓ walk through: the rows, else the recent conversations that are listed.
    private var navigable: [String] { showsRecent ? recent.map(\.id) : rows.map(\.id) }

    var selectedRow: AgentRow? { rows.first { $0.id == selected } }

    /// Whether files dropped on a row would be taken: the selected row's word, else any row's.
    var takesFiles: Bool { selectedRow.map(\.takesDrops) ?? rows.contains(where: \.takesDrops) }

    /// The note to say under the tab: the selected row's, else the first row's that has one.
    var footerNote: (title: String, text: String)? {
        let row = selectedRow.flatMap { notes[$0.id] != nil ? $0 : nil } ?? rows.first { notes[$0.id] != nil }
        return row.flatMap { row in notes[row.id].map { (row.title, $0) } }
    }

    /// A key the tab uses while it is showing and no field has the keyboard. True when it was used, so the notch's monitor swallows it.
    @discardableResult
    func perform(_ key: AgentKey) -> Bool {
        if diffing != nil {
            // The arrows are the diff's even at its first or last change, so they don't scroll anything behind it.
            guard key == .left || key == .right else { return false }
            stepDiff(key == .left ? -1 : 1)
            return true
        }
        switch key {
        case .left, .right:
            return false
        case .up, .down:
            let ids = navigable
            guard !ids.isEmpty else { return false }
            let at = selected.flatMap(ids.firstIndex(of:))
            let next = at.map { key == .down ? min($0 + 1, ids.count - 1) : max($0 - 1, 0) } ?? (key == .down ? 0 : ids.count - 1)
            select(ids[next])
            return true
        case .activate:
            if let row = selectedRow { focus(row); return true }
            guard let conversation = recent.first(where: { $0.id == selected }), showsRecent else { return false }
            resume(conversation)
            return true
        case .message:
            guard let row = selectedRow else { return false }
            compose(row)
            return true
        }
    }

    private func pruneSelection() {
        if let selected, !navigable.contains(selected) { self.selected = nil }
        if let diffing, !rows.contains(where: { $0.id == diffing.id && $0.edits.indices.contains(diffing.index) }) {
            // The turn moved on (a new prompt) or the row went: back to the list.
            self.diffing = rows.first { $0.id == diffing.id && !$0.edits.isEmpty }.map { DiffFocus(id: $0.id, index: $0.edits.count - 1) }
        }
    }

    /// Whether the tab says it has nothing: no session is listed and no recent conversation turned up.
    var showsEmptyMessage: Bool { rows.isEmpty && recent.isEmpty && recentLoaded }

    /// What the tab says when no session is listed.
    var emptyMessage: String {
        connected ? String(localized: "No sessions used in the last 3 hours")
                  : String(localized: "Connect Claude Code and Codex in Settings › Alerts to see their sessions here")
    }

    /// The entry with the target found in its process's environment when its hook named none.
    private func withDerivedInput(_ entry: AgentBoard.Entry) -> AgentBoard.Entry {
        guard entry.agent.input == nil, let derived = derivedTargets[entry.key], derived.pid == entry.agent.pid else { return entry }
        return Self.entry(entry, input: derived.input)
    }

    private static func entry(_ entry: AgentBoard.Entry, input: AgentInput) -> AgentBoard.Entry {
        var agent = entry.agent
        agent.input = input
        return AgentBoard.Entry(source: entry.source, id: entry.id, agent: agent)
    }

    /// What the look at Ghostty's tabs came to for a session: the input to type into (verified), or why there is none.
    private struct GhosttyOutcome {
        var input: AgentInput?
        var pick: GhosttyPick?
        var block: AgentRow.InputBlock?
    }

    /// Resolves each session found under Ghostty to its tab, from the tabs listed in the pass and the session's folder and name as the
    /// transcripts have them now; all of them together, as sessions sharing a folder must be told apart from each other.
    private func ghosttyOutcomes(_ entries: [AgentBoard.Entry]) -> [String: GhosttyOutcome] {
        let here = entries.filter { $0.agent.pid != nil && ghosttyHosted[$0.key] == $0.agent.pid }
        guard !here.isEmpty else { return [:] }
        let sessions = here.map { entry -> GhosttySession in
            let transcript = fixed[entry.key] ?? AgentRow.transcriptKey(entry.agent).flatMap(transcripts.transcript)
            let cwd = [entry.agent.cwd, transcript?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
            return GhosttySession(key: entry.key, cwd: cwd, name: transcript?.name.flatMap { $0.isEmpty ? nil : $0 })
        }
        switch ghosttyListing {
        case .notAllowed?:
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, GhosttyOutcome(block: .notAllowed(TerminalScripts.ghosttyID))) })
        case .terminals(let terminals)?:
            let tabs = Ghostty.resolve(sessions.filter { !$0.cwd.isEmpty }, in: terminals)
            return Dictionary(uniqueKeysWithValues: sessions.map { session in
                switch tabs[session.key] {
                case .terminal(let id, let usesName)?:
                    return (session.key, GhosttyOutcome(input: .ghostty(cwd: session.cwd, name: session.name),
                                                        pick: GhosttyPick(terminal: id, usesName: usesName)))
                case .ambiguous?: return (session.key, GhosttyOutcome(block: .ambiguousTab))
                case .absent?, nil: return (session.key, GhosttyOutcome())
                }
            })
        case .unavailable?, nil:
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, GhosttyOutcome()) })
        }
    }

    private func rebuild(_ entries: [AgentBoard.Entry]) {
        let ghostty = ghosttyOutcomes(entries)
        ghosttyPicks = ghostty.compactMapValues(\.pick)
        let next = AgentRow.sorted(AgentRow.sharingTerminals(entries.map(withDerivedInput).map { entry in
            let outcome = ghostty[entry.key]
            var entry = entry
            if let input = outcome?.input { entry = Self.entry(entry, input: input) }
            return AgentRow(entry, transcript: fixed[entry.key] ?? AgentRow.transcriptKey(entry.agent).flatMap(transcripts.transcript),
                     inputVerified: outcome?.input != nil || (entry.agent.input.map { verifiedTargets[entry.key] == VerifiedTarget(input: $0, pid: entry.agent.pid) } ?? false),
                     multiplexed: entry.agent.pid.flatMap { environmentCache[$0] }.map(AgentHook.inMultiplexer) ?? false,
                     hostApp: hostApps[entry.key],
                     checked: entry.agent.pid.map { checked.contains(Self.checkedKey(entry.key, $0)) } ?? true,
                     blockedBy: outcome?.block)
        }))
        if next != rows { rows = next }
        // The field lets go when its row goes away or starts waiting on a prompt: typing could answer it.
        if let composing, !rows.contains(where: { $0.id == composing && $0.acceptsInput }) { self.composing = nil }
        let kept = notes.filter { id, _ in rows.contains { $0.id == id } }
        if kept.count != notes.count { notes = kept }
    }
}

/// The keys the tab uses, as the notch's key monitor hands them over (see `AgentsTabModel.perform`).
enum AgentKey: Equatable {
    case up, down
    /// ← →: the change before or after, in a diff.
    case left, right
    /// Return: go to the selected session's terminal, or resume the selected conversation.
    case activate
    /// ⌘M: open the message field for the selected session.
    case message

    /// nil for any other key, or one with Shift, Option or Control held, which belongs to someone else. ⌘M is matched by the
    /// character the layout gives the key (`charactersIgnoringModifiers`), not its key code, which is another letter on AZERTY.
    init?(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        let held = modifiers.intersection([.command, .shift, .option, .control])
        switch (keyCode, held) {
        case (126, []): self = .up
        case (123, []): self = .left
        case (124, []): self = .right
        case (125, []): self = .down
        case (36, []), (76, []): self = .activate
        case (_, .command) where characters?.lowercased() == "m": self = .message
        default: return nil
        }
    }
}

private enum Ink {
    static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let working = Color(red: 0.31, green: 0.82, blue: 0.47)
}

private enum Metrics {
    static let row: CGFloat = 24
    /// The last step's line under a row.
    static let activity: CGFloat = 16
    static let expanded: CGFloat = 52
    static let titleWidth: CGFloat = 120
    static let tag: CGFloat = 24
    static let meter: CGFloat = 36
    static let figure: CGFloat = 32
    /// The time since a change, wide enough for the longest translation ("59 Min.").
    static let age: CGFloat = 40
}

struct AgentsTab: View {
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        Group {
            if model.rows.isEmpty && model.recent.isEmpty {
                Text(verbatim: model.showsEmptyMessage ? model.emptyMessage : "")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The times count on from the minute they were drawn.
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 0) {
                        if model.rows.isEmpty {
                            RecentList(model: model, now: context.date)
                        } else if let focus = model.diffing, let row = model.rows.first(where: { $0.id == focus.id }), row.edits.indices.contains(focus.index) {
                            AgentDiffView(row: row, index: focus.index, model: model)
                        } else {
                            AgentList(model: model, now: context.date)
                            if let to = model.composing.flatMap({ id in model.rows.first { $0.id == id } }) {
                                // Per recipient: a draft typed to one session must not go to another.
                                AgentComposer(row: to, model: model).id(to.id)
                            } else {
                                AgentFooter(model: model)
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

private struct AgentList: View {
    @ObservedObject var model: AgentsTabModel
    let now: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(model.rows) { AgentRowView(row: $0, now: now, model: model).id($0.id) }
                }
            }
            .onChange(of: model.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }
}

/// A state you can tell without colour: a filled dot with a ring (needs you), a turning arc (working), a hollow ring (idle).
private struct StateMark: View {
    let row: AgentRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch row.state {
            case .waiting:
                Circle().fill(Ink.waiting).frame(width: 8, height: 8)
                Circle().stroke(Ink.waiting.opacity(0.4), lineWidth: 1).frame(width: 13, height: 13)
            case .working:
                Circle().stroke(Ink.working.opacity(0.25), lineWidth: 1.6).frame(width: 11, height: 11)
                // The arc stands still under Reduce Motion.
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                    Circle().trim(from: 0, to: 0.3).stroke(Ink.working, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 11, height: 11).rotationEffect(.degrees(turn - 90))
                }
            case .idle:
                Circle().stroke(.white.opacity(0.55), lineWidth: 1.2).frame(width: 10, height: 10)
            }
        }
        .frame(width: 16, height: 16)
        .help(row.stateLabel)
        .accessibilityElement()
        .accessibilityLabel(row.stateLabel)
    }
}

/// A key as a keycap; `dim` when it does nothing now.
private struct Keycap: View {
    let key: String
    var dim = false

    var body: some View {
        Text(verbatim: key).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(dim ? 0.45 : 0.7))
            .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(dim ? 0.05 : 0.1)))
            .accessibilityHidden(true)
    }
}

/// An icon button with no label of its own: 24 x 22 pt, always there, brighter on the selected row and under the pointer. Disabled it
/// is a dashed outline, not only dimmer, and says why in its tooltip.
private struct RowIconButton: View {
    let symbol: String
    let title: String
    /// Why it is disabled; nil when it works.
    let reason: String?
    let hot: Bool
    let action: () -> Void
    @State private var hovering = false

    private var enabled: Bool { reason == nil }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(.white.opacity(enabled ? (hot || hovering ? 0.9 : 0.55) : 0.4))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(enabled && hovering ? 0.1 : 0)))
                .overlay {
                    if !enabled { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(reason ?? title)
        .accessibilityLabel(title)
        .accessibilityHint(reason ?? "")
    }
}

/// The context meter: 36 x 3 pt, the label beside it carries the number.
private struct ContextMeter: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.15))
            Capsule().fill(.white.opacity(0.7)).frame(width: max(3, Metrics.meter * fraction))
        }
        .frame(width: Metrics.meter, height: 3)
    }
}

private struct AgentRowView: View {
    let row: AgentRow
    let now: Date
    @ObservedObject var model: AgentsTabModel
    @State private var hovering = false
    @State private var dropTargeted = false

    private var selected: Bool { model.selected == row.id }
    private var composing: Bool { model.composing == row.id }
    private var dim: Bool { row.state == .idle }
    /// A row that asks opens to say what, unless the composer needs the room.
    private var open: Bool { row.asksForAnswer && model.composing == nil }

    var body: some View {
        VStack(spacing: 0) {
            line
            if open, let prompt = row.waitingPrompt { promptLine(prompt) }
            else if row.showsActivity, let activity = row.activity { activityLine(activity) }
        }
        .padding(.horizontal, 8)
        .frame(height: open ? Metrics.expanded : row.showsActivity ? Metrics.row + Metrics.activity : Metrics.row)
        .background { background }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            } else if composing {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        // The buttons inside take their own clicks; this is the rest of the row.
        .onTapGesture { model.click(row, count: NSApp.currentEvent?.clickCount ?? 1) }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
        // Only a session that takes input accepts files; otherwise the drop isn't taken at all.
        .onDrop(of: row.takesDrops ? [.fileURL] : [], isTargeted: $dropTargeted) { providers in
            ShelfSharing.loadURLs(from: providers) { model.send(files: $0, to: row) }
            return true
        }
        .help(row.path.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
    }

    /// Hover is a faint surface, selected a stronger one with a thin border (white 0.4 on the panel is 3.7:1). A row that asks is
    /// tinted orange instead, with no glow.
    @ViewBuilder private var background: some View {
        if row.asksForAnswer {
            RoundedRectangle(cornerRadius: 8).fill(Ink.waiting.opacity(selected ? 0.16 : hovering ? 0.13 : 0.1))
            RoundedRectangle(cornerRadius: 8).stroke(Ink.waiting.opacity(0.35), lineWidth: 0.75)
        } else if selected {
            Color.clear.surface(RoundedRectangle(cornerRadius: 8), opacity: 0.1)
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.4), lineWidth: 0.75)
        } else if hovering || dropTargeted {
            Color.clear.surface(RoundedRectangle(cornerRadius: 8), opacity: 0.06)
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            StateMark(row: row)
            Text(verbatim: row.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(.white.opacity(dim ? 0.75 : 1))
                .frame(width: Metrics.titleWidth, alignment: .leading)
                .help(Text(verbatim: row.title))
            HStack(spacing: 8) {
                Text(verbatim: row.meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).truncationMode(.tail)
                    .help(Text(verbatim: row.meta))
                if let background = row.backgroundChip {
                    Text(verbatim: background).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.working)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Capsule().strokeBorder(Ink.working.opacity(0.7), lineWidth: 0.75))
                        .fixedSize().layoutPriority(1)
                }
                if let chip = row.modeChip {
                    Text(verbatim: chip.text).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(chip.warns ? Ink.waiting : .white.opacity(0.7))
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Capsule().strokeBorder(chip.warns ? Ink.waiting.opacity(0.7) : .white.opacity(0.4), lineWidth: 0.75))
                        .fixedSize().layoutPriority(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                RowIconButton(symbol: "terminal", title: row.host == Paseo.name ? String(localized: "Open in Paseo") : String(localized: "Go to terminal"), reason: row.terminalBlock,
                              hot: selected || hovering) { model.focus(row) }
                RowIconButton(symbol: "paperplane", title: String(localized: "Message"), reason: row.blockReason,
                              hot: selected || hovering) { model.compose(row) }
            }
            .layoutPriority(2)
            context
            Text(verbatim: AgentRow.elapsed(since: row.since, now: now) ?? "").font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: Metrics.age, alignment: .trailing)
        }
        .frame(height: Metrics.row)
    }

    /// The meter and the count; the space stays when the transcript has none, so the columns line up.
    @ViewBuilder private var context: some View {
        if let fraction = row.contextFraction, let label = row.tokensLabel, let description = row.contextDescription {
            HStack(spacing: 4) {
                ContextMeter(fraction: fraction)
                Text(verbatim: label).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    .frame(width: Metrics.figure, alignment: .trailing)
            }
            .help(Text(verbatim: description))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
        } else {
            Color.clear.frame(width: Metrics.meter + 4 + Metrics.figure, height: 1)
        }
    }

    /// "Edited Sources/Login.swift +12 −3 [Show diff]", under the title.
    private func activityLine(_ activity: AgentActivity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: activity.verb.symbol).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).frame(width: 12)
            Text(verbatim: activity.verb.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize()
            Text(verbatim: activity.edit.map { row.shortPath($0.path) } ?? row.shortPath(activity.subject))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.middle)
            if let edit = activity.edit {
                DiffCounts(added: edit.added, removed: edit.removed)
                Button { model.showDiff(row) } label: {
                    Text("Show diff").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(.white.opacity(0.1))).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 24)
        .frame(height: Metrics.activity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func promptLine(_ prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: prompt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { model.focus(row) } label: {
                HStack(spacing: 4) {
                    Text("Answer in terminal").font(.system(size: 11, weight: .medium))
                    if selected { Keycap(key: "↵") }
                }
                .foregroundStyle(Ink.waiting)
                .padding(.leading, 8).padding(.trailing, selected ? 4 : 8).frame(height: Metrics.tag)
                .background(Capsule().fill(Ink.waiting.opacity(0.16)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Answer in terminal"))
        }
        .padding(.leading, 24)
        .frame(height: Metrics.expanded - Metrics.row, alignment: .top)
    }
}

/// Under the rows: how many are in which state, then what the selected row can do. A row that can't take a message says why.
private struct AgentFooter: View {
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        let selected = model.selectedRow
        let note = model.footerNote
        let left = note.map { "\($0.title): \($0.text)" } ?? AgentRow.summary(model.rows)
        // Without room for all of it the summary goes first, but a note stays: it is the answer to what was just done. It sheds the
        // file-drop text and the ↑↓ hint before it gives way.
        ViewThatFits(in: .horizontal) {
            footer(left: left, warns: note != nil, selected: selected, trimmed: false)
            footer(left: left, warns: note != nil, selected: selected, trimmed: note != nil)
            footer(left: nil, warns: false, selected: selected, trimmed: false)
        }
        .frame(height: Metrics.row)
    }

    private func footer(left: String?, warns: Bool, selected: AgentRow?, trimmed: Bool) -> some View {
        let blocked = selected?.blockReason
        return HStack(spacing: 16) {
            if let left {
                Text(verbatim: left).font(.system(size: 11)).foregroundStyle(warns ? Ink.waiting : .white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 4)
            // A row that can't be sent to takes no drops either.
            if model.takesFiles, !trimmed {
                Text("Drop files on a row").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            if !trimmed { HStack(spacing: 4) { Keycap(key: "↑↓"); hint("Select") } }
            if let selected {
                HStack(spacing: 4) { Keycap(key: "↵", dim: !selected.focusable); hint(selected.host == Paseo.name ? "Open in Paseo" : "Terminal", dim: !selected.focusable) }
                HStack(spacing: 4) {
                    Keycap(key: "⌘M", dim: blocked != nil)
                    hint("Message", dim: blocked != nil, struck: blocked != nil)
                    if let blocked {
                        Text(verbatim: "· \(blocked)").font(.system(size: 11)).foregroundStyle(Ink.waiting).lineLimit(1).truncationMode(.tail)
                            .help(Text(verbatim: blocked))
                    }
                }
            }
        }
    }

    private func hint(_ key: LocalizedStringKey, dim: Bool = false, struck: Bool = false) -> some View {
        Text(key).font(.system(size: 11)).foregroundStyle(.white.opacity(dim ? 0.5 : 0.65)).lineLimit(1)
            .strikethrough(struck, color: .white.opacity(0.5))
    }
}

/// The footer while a message is typed: to whom (the row whose button was pressed), the field, and how to send or cancel. Return
/// sends the message to the row and closes it. Escape (see the notch's key monitor) and losing the keyboard focus close it without sending.
private struct AgentComposer: View {
    let row: AgentRow
    @ObservedObject var model: AgentsTabModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { row.acceptsInput && AgentSend.message(text) != nil }

    var body: some View {
        HStack(spacing: 8) {
            Text("To").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 4) {
                StateMark(row: row).scaleEffect(0.8).frame(width: 12, height: 12)
                Text(verbatim: row.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Button { model.cancelCompose() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Cancel"))
            }
            .padding(.leading, 8).padding(.trailing, 4).frame(height: Metrics.tag)
            .background(Capsule().fill(.white.opacity(0.1)))
            // The focus ring is 2 pt of the accent colour on the field itself.
            TextField("Message", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { model.submit(message: text, to: row) }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                .accessibilityLabel(Text("Message to \(row.title)"))
            Keycap(key: "esc").help(Text("Cancel"))
            Button { model.submit(message: text, to: row) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    .foregroundStyle(canSend ? Color.accentColor : .white.opacity(0.25))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(Text("Send"))
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .surface(RoundedRectangle(cornerRadius: 8), opacity: 0.09)
        .onAppear { focused = true }
        .onDisappear { model.cancelCompose(row: row.id) }
        .onChange(of: focused) { _, isFocused in if !isFocused { model.cancelCompose(row: row.id) } }
    }
}

/// With no session open: the conversations that can be picked up again, and the tab's empty sentence under them.
private struct RecentList: View {
    @ObservedObject var model: AgentsTabModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 8).frame(height: Metrics.row).accessibilityAddTraits(.isHeader)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(model.recent) { RecentRowView(conversation: $0, now: now, model: model) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
                Text(verbatim: model.resumeNote ?? model.emptyMessage).font(.system(size: 11))
                    .foregroundStyle(model.resumeNote == nil ? .white.opacity(0.65) : Ink.waiting).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 4) { Keycap(key: "↑↓"); Text("Select").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)) }
            }
            .padding(.horizontal, 8).frame(height: Metrics.row)
        }
    }
}

private struct RecentRowView: View {
    let conversation: RecentConversation
    let now: Date
    @ObservedObject var model: AgentsTabModel
    @State private var hovering = false

    private var selected: Bool { model.selected == conversation.id }
    private var meta: String { conversation.metaParts.joined(separator: " · ") }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 16).accessibilityHidden(true)
            Text(verbatim: conversation.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .frame(width: Metrics.titleWidth, alignment: .leading)
                .help(Text(verbatim: conversation.title))
            Text(verbatim: meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.tail)
                .help(Text(verbatim: conversation.cwd))
            Spacer(minLength: 4)
            if selected {
                Button { model.resume(conversation) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.forward").font(.system(size: 11)).accessibilityHidden(true)
                        Text("Resume").font(.system(size: 11, weight: .medium))
                        Keycap(key: "↵")
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.leading, 8).padding(.trailing, 4).frame(height: Metrics.tag)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text("Resume"))
            }
            Text(verbatim: conversation.age(now: now) ?? "").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                .frame(width: Metrics.age, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background {
            if selected {
                Color.clear.surface(RoundedRectangle(cornerRadius: 8), opacity: 0.1)
            } else if hovering {
                Color.clear.surface(RoundedRectangle(cornerRadius: 8), opacity: 0.06)
            }
        }
        .contentShape(Rectangle())
        // Resuming is what a click on a conversation always did.
        .onTapGesture { model.select(conversation.id); model.resume(conversation) }
        .onHover { hovering = $0 }
    }
}

/// "+12 −3", green and red.
private struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(DiffInk.added) }
            if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(DiffInk.removed) }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .fixedSize()
    }
}

private enum DiffInk {
    static let added = Color(red: 0.35, green: 0.85, blue: 0.45)
    static let removed = Color(red: 1, green: 0.42, blue: 0.4)
}

/// One change of a session's turn in place of the list: the file, its counts, the lines with what was removed and added marked,
/// and ← → to the change before or after.
private struct AgentDiffView: View {
    let row: AgentRow
    let index: Int
    @ObservedObject var model: AgentsTabModel

    var body: some View {
        let edit = row.edits[index]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { model.closeDiff() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Back"))
                Text(verbatim: row.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                Text(verbatim: row.shortPath(edit.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.middle)
                DiffCounts(added: edit.added, removed: edit.removed)
                Spacer(minLength: 4)
                Text("Change \(index + 1) of \(row.edits.count) this turn").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).fixedSize()
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(edit.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .foregroundStyle(line.kind == .added ? DiffInk.added : line.kind == .removed ? DiffInk.removed : .clear)
                                .frame(width: 10)
                            Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(.white.opacity(line.kind == .same ? 0.6 : 0.95))
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background((line.kind == .added ? DiffInk.added : line.kind == .removed ? DiffInk.removed : .clear).opacity(0.14))
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("← → the change before or after · Esc back to the list").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }
}
