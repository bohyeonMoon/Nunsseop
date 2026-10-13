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
        /// Ghostty has several tabs in the session's folder and nothing tells which is its own.
        case ambiguousTab
        /// macOS hasn't allowed Nunsseop to control the app (Automation), so the session's tab can't be looked for.
        case notAllowed(String)
        /// The check of its terminal hasn't covered the row yet; the reason may turn out to be none.
        case checking

        var message: String {
            switch self {
            case .prompt: String(localized: "Answer the prompt first")
            case .multiplexer: String(localized: "Can't send into tmux, zellij or screen")
            case .unsupportedApp(let app): String(localized: "\(AgentRow.appName(app)) doesn't let Nunsseop type into it")
            case .noProcess: String(localized: "Restart this session to send to it")
            case .unconfirmed: String(localized: "Couldn't confirm which terminal this session is in")
            case .ambiguousTab: String(localized: "There are several Ghostty tabs in this folder, so Nunsseop can't tell which one")
            case .notAllowed(let app): TerminalScripts.notAllowedNote(app)
            case .checking: String(localized: "Checking…")
            }
        }
    }

    /// The terminals that have an input API (see `AgentInput`); the other apps a session can run in have none.
    static let inputApps: Set<String> = [TerminalScripts.terminalID, TerminalScripts.itermID, MuxyNotice.bundleID, Cmux.bundleID,
                                         WezTerm.bundleID, Kitty.bundleID, TerminalScripts.ghosttyID]

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
        since = agent.since
        path = [agent.cwd, transcript?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty }
        model = transcript?.model
        tokens = transcript?.tokens
        mode = transcript?.mode
        name = transcript?.name
        target = Self.target(for: agent) ?? Self.bundleID(hostApp).map(Target.app)
        input = agent.input
        pid = agent.pid
        self.inputVerified = inputVerified
        promptOnTerminal = agent.promptMayBeOpen
        // Only a hook session can be restarted, and only its hook names an app or a multiplexer; any other source (gjc, a herdr
        // pane without its socket) can only be unconfirmed.
        let hook = entry.source.hasPrefix("hooks:")
        if agent.inMultiplexer || multiplexed {
            notOffered = .multiplexer
        } else if !checked && agent.pid != nil {
            // The process environment may still say tmux, and the process tree may still name another app.
            notOffered = .checking
        } else if let blockedBy {
            notOffered = blockedBy
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
        case .herdr: true
        case .muxy, .cmux, .terminalApp, .iterm, .wezterm, .kitty, .ghostty: inputVerified
        }
    }

    /// Whether going to the session does anything: there is an app or pane to go to, or a verified terminal to select the session's tab in.
    var focusable: Bool { target != nil || offersInput }

    /// Whether text can be sent to the session now: its terminal has an input API and no prompt may be waiting there.
    var acceptsInput: Bool { offersInput && !promptOnTerminal && AgentSend.accepts(state: state, finished: finished) }

    /// Its terminal takes input, but a prompt waits for the answer first.
    var inputBlocked: Bool { offersInput && !acceptsInput }

    /// Why the Message button is disabled for this row, nil when it works. A prompt only counts for a row that could be typed into:
    /// answering it would not make any other row sendable.
    var inputBlock: InputBlock? { offersInput ? (acceptsInput ? nil : .prompt) : notOffered }

    /// The sentence that says it, shown in the row's strip.
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

    /// The tool's name as it presents itself; herdr's own name for an agent that isn't one of ours.
    static func toolName(_ raw: String?) -> String {
        if let kind = kind(raw) { return kind.displayName }
        return raw.flatMap { $0.isEmpty ? nil : $0 } ?? "herdr"
    }

    static func kind(_ tool: String?) -> AgentKind? { AgentKind(tool: tool) }

    /// Where the transcript is looked for; herdr gives the session id of the agent in a pane.
    static func transcriptKey(_ agent: AgentBoard.Agent) -> AgentTranscripts.Key? {
        guard let kind = kind(agent.tool), let session = agent.session else { return nil }
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
    /// Whether a tool that reports its sessions is connected, which tells an empty tab from one waiting for a connection.
    @Published private(set) var connected = false
    /// The row whose action strip is unfolded, by `AgentRow.id`; one at a time.
    @Published private(set) var unfolded: String?
    /// The row whose message field is open, by `AgentRow.id`: the field has the keyboard, and the notch stays open while it does.
    @Published private(set) var composing: String?
    /// A short note under a row whose message or files didn't go out, by `AgentRow.id`.
    @Published private(set) var notes: [String: String] = [:]
    /// Under the recent conversations: macOS didn't let Nunsseop open one in the terminal chosen (see `Resume.notAllowedNotification`).
    @Published private(set) var resumeNote: String?
    private var denial: AnyCancellable?
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
    // Vars only for `--demo-agents`, which swaps in fakes (see `AgentBoard.demoSender`).
    private var sender: AgentSender
    private var clis: () -> TerminalCLIs
    private var targets: AgentTargetCheck
    private let environments: ProcessEnvironment
    private let scripts: AppleScriptRunner
    private let focuser: AgentFocuser
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
    /// The app found above the process of each session whose hook named none, by `Entry.key`; for the tooltip of a row that can't be typed into.
    private var hostApps: [String: String] = [:]
    /// The entries a verification pass has covered: `Entry.key` and process, see `checkedKey`. A row outside it is still being checked.
    private var checked: Set<String> = []
    private var scanner = RecentConversations()
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
        let text = TerminalScripts.notAllowedNote(app)
        resumeNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteDuration) { [weak self] in
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

    private func loaded(_ updated: AgentTranscripts) {
        transcripts = updated
        loading = false
        rebuild(board.entries(now: asOf))
        if changedWhileLoading {
            changedWhileLoading = false
            refresh()
        }
    }

    private static func checkedKey(_ key: String, _ pid: Int32) -> String { "\(key)|\(pid)" }

    /// Checks, off the main thread, that each session's process runs in the terminal its hook named (see `AgentTargetCheck`); until
    /// then, or when it doesn't, the row offers no input. Muxy's session list is read once for all of them. A session whose hook named
    /// none (it started before the hook sent the terminal's variables) is looked at through its process's own environment.
    private func verifyTargets(_ entries: [AgentBoard.Entry]) {
        let named = entries.compactMap { entry -> (key: String, target: VerifiedTarget)? in
            guard let input = entry.agent.input, !isHerdr(input) else { return nil }
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
            ghosttyListing = nil
            if !checked.isEmpty { checked = [] }
            return
        }
        guard !verifying else { verifyWanted = true; return }
        verifying = true
        let targets = targets, environments = environments, muxy = clis().muxy, others = Set(entries.compactMap { $0.agent.pid })
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
            let verified = candidates.filter { targets.verified($0.target.input, pid: $0.target.pid, muxySessions: sessions, others: others) }
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
                                 ghostty: (inGhostty, listing))
        }
    }

    private func verified(_ targets: [String: VerifiedTarget], derived: [String: VerifiedTarget], environments: [Int32: [String: String]],
                          hosts: [String: String], covered: Set<String>, ghostty: (hosted: [String: Int32], listing: GhosttyListing?)) {
        checked = covered
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

    /// A click on a row unfolds its action strip and folds the one before it; a click on the unfolded row folds it. Folding ends typing.
    func toggle(_ row: AgentRow) {
        composing = nil
        unfolded = unfolded == row.id ? nil : row.id
    }

    /// Opens the message field in the strip of a row that takes input now, closing any other.
    func compose(_ row: AgentRow) {
        guard let current = rows.first(where: { $0.id == row.id }), current.acceptsInput else { return }
        unfolded = current.id
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
        switch AgentFocus.plan(for: current, clis: clis(), ghostty: ghosttyPicks[row.id]) {
        case .herdr(let pane, let socket): focuser.herdr(pane, socket)
        case .app(let app): focuser.activate(app)
        case .nothing: break
        case .terminal(let steps, let app):
            guard let input = current.input else { return }
            let focuser = focuser, targets = targets, pid = current.pid, id = row.id
            let others = Set(board.entries(now: asOf).compactMap { $0.agent.pid })
            Task.detached(priority: .userInitiated) { [weak self] in
                let outcome = targets.hosted(input, pid: pid, others: others) ? focuser.run(steps) : .failed
                await self?.focused(outcome, id, app)
            }
        }
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
        guard let steps = AgentSend.steps(input, text: text, submit: submit, clis: clis(), ghostty: ghosttyPicks[row.id]) else {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteDuration) { [weak self] in
            MainActor.assumeIsolated { if self?.notes[id] == text { self?.notes[id] = nil } }
        }
    }

    /// How long the note under a row stays.
    static let noteDuration: TimeInterval = 6

    private func checkConnected() -> Bool {
        if let isConnected { return isConnected() }
        // gjc needs no connection: its sessions are read from its own files.
        return NotifyIntegration.$homeOverride.withValue(home()) {
            NotifyIntegration.reportingSessions.contains(where: \.isInstalled)
                || FileManager.default.fileExists(atPath: home().appendingPathComponent(".gjc").path)
        }
    }

    /// Recent conversations are listed only when no session is: with sessions open they are noise next to them.
    var showsRecent: Bool { rows.isEmpty && !recent.isEmpty }

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
        if let unfolded, !rows.contains(where: { $0.id == unfolded }) { self.unfolded = nil }
        // The field lets go when its row goes away or starts waiting on a prompt: typing could answer it.
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
                            if model.showsRecent {
                                Text("Recent")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                if let note = model.resumeNote {
                                    Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                                }
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

    private var isUnfolded: Bool { model.unfolded == row.id }

    var body: some View {
        // A click always does something: it unfolds the strip with what can be done with the session. The strip is outside the
        // clickable part, so its field and buttons take their own clicks.
        VStack(alignment: .leading, spacing: 4) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, isUnfolded ? 0 : 6)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(row) }
            if isUnfolded {
                AgentActionStrip(row: row, model: model).padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .opacity(row.state == .idle ? 0.6 : 1)
        .surface(RoundedRectangle(cornerRadius: 10), opacity: isUnfolded || dropTargeted ? 0.16 : hovering ? 0.12 : 0.08)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5)
            } else if isUnfolded {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
        // Only a session that takes input accepts files; otherwise the drop isn't taken at all.
        .onDrop(of: row.acceptsInput ? [.fileURL] : [], isTargeted: $dropTargeted) { providers in
            ShelfSharing.loadURLs(from: providers) { model.send(files: $0, to: row) }
            return true
        }
        .help(row.path.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
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
                // Unfolded, the strip shows the notes.
                if !isUnfolded, let note = model.notes[row.id] {
                    Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }
}

/// What can be done with a session, under its row: go to its terminal, or message it. A row that can't take a message says why.
private struct AgentActionStrip: View {
    let row: AgentRow
    @ObservedObject var model: AgentsTabModel

    private var typing: Bool { model.composing == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if typing {
                AgentMessageField(row: row, model: model)
            } else {
                HStack(spacing: 6) {
                    StripButton(symbol: "arrow.up.forward.app", title: "Go to terminal", enabled: row.focusable) { model.focus(row) }
                    StripButton(symbol: "paperplane.fill", title: "Message", enabled: row.acceptsInput) { model.compose(row) }
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
                if let reason = row.blockReason {
                    Text(verbatim: reason).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                }
            }
            if let note = model.notes[row.id] {
                Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}

private struct StripButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(enabled ? 0.15 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The one-line field in the strip's place: Return sends the message to the row and closes it. Escape (see the notch's key monitor)
/// and losing the keyboard focus close it without sending.
private struct AgentMessageField: View {
    let row: AgentRow
    @ObservedObject var model: AgentsTabModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { row.acceptsInput && AgentSend.message(text) != nil }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Message", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focused)
                .onSubmit { model.submit(message: text, to: row) }
                .padding(.horizontal, 8).frame(height: 24)
                .surface(RoundedRectangle(cornerRadius: 6), opacity: 0.1)
            Button { model.submit(message: text, to: row) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                    .foregroundStyle(canSend ? Color.accentColor : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .frame(height: 26)
        .onAppear { focused = true }
        .onDisappear { model.cancelCompose(row: row.id) }
        .onChange(of: focused) { _, isFocused in if !isFocused { model.cancelCompose(row: row.id) } }
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
