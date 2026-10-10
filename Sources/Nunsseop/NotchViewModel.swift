import AppKit
import Combine

/// Which Claude or Codex limit an idle ear shows as "left".
enum AIWindow: String, CaseIterable, Identifiable {
    case tighter, session, weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tighter: return String(localized: "Whichever is tighter")
        case .session: return String(localized: "5-hour")
        case .weekly: return String(localized: "Weekly")
        }
    }
}

/// What each side of the collapsed notch shows while nothing is playing or running.
enum IdleItem: String, CaseIterable, Identifiable {
    case none, claude, codex, battery, weather, date, agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .claude: return String(localized: "Claude Code left")
        case .codex: return String(localized: "Codex left")
        case .battery: return String(localized: "Battery")
        case .weather: return String(localized: "Weather")
        case .date: return String(localized: "Date")
        case .agents: return String(localized: "Agents at work")
        }
    }

    var usesAIUsage: Bool { self == .claude || self == .codex }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, timer, clipboard, notes, tools, system, apps, search, emoji, ai, notices, mirror

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .timer: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "note.text"
        case .tools: return "switch.2"
        case .system: return "cpu"
        case .apps: return "square.grid.3x3.fill"
        case .search: return "magnifyingglass"
        case .emoji: return "face.smiling"
        case .ai: return "sparkles"
        case .notices: return "bell.fill"
        case .mirror: return "camera.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .shelf: return String(localized: "Shelf")
        case .timer: return String(localized: "Timer")
        case .clipboard: return String(localized: "Clipboard")
        case .notes: return String(localized: "Notes")
        case .tools: return String(localized: "Tools")
        case .system: return String(localized: "System")
        case .apps: return String(localized: "Apps")
        case .search: return String(localized: "Search")
        case .emoji: return String(localized: "Emoji")
        case .ai: return String(localized: "AI usage")
        case .notices: return String(localized: "Notifications")
        case .mirror: return String(localized: "Mirror")
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published private(set) var isExpanded = false
    @Published var tab: NotchTab = .home
    @Published private(set) var showsLiveActivity = false
    @Published private(set) var sneakPeekPending = false
    /// Set briefly when a call with a meeting name starts.
    @Published private(set) var callPeekPending = false

    let settings: AppSettings
    let nowPlaying = NowPlayingController()
    let shelf = ShelfStore()
    let hud: HUDCenter
    let calendar = CalendarModel()
    let mirror = MirrorModel()
    let timer = TimerModel()
    let clipboard = ClipboardHistory()
    let notes = NotesModel()
    let tools = ToolsModel()
    let appVolume = AppVolumeModel()
    let screenshots = ScreenshotWatcher()
    let capsLock = CapsLockWatcher()
    let notifyServer = NotifyServer()
    let muxy = MuxyWatcher()
    let notices = NoticeLog()
    let cmux = CmuxWatcher()
    let herdr = HerdrSessions()
    let agents = AgentBoard()
    let agentHooks: AgentHooks
    let tmux = TmuxWatcher()
    let stats = SystemStats()
    let launcher = AppLauncher()
    let lyrics = LyricsModel()
    let weather = WeatherModel()
    let downloads = DownloadWatcher()
    let peripherals = PeripheralMonitor()
    let privacy = PrivacyMonitor()
    let calls = CallMonitor()
    let callControls = CallControlsModel()
    let appMenus = AppMenuWatcher()
    let emoji = EmojiModel()
    let aiUsage = AIUsageModel()
    lazy var search = QuickSearchModel(clipboard: clipboard, emoji: emoji, tools: tools)
    let recorder = ScreenRecorder()
    /// Set when opened by the hotkey; the notch then stays open until the pointer visits it or Escape is pressed.
    @Published var pinned = false
    /// The pointer is over the collapsed shape; the eyebrow on displays without a notch lifts.
    @Published var pointerOverCollapsed = false {
        didSet { if pointerOverCollapsed != oldValue { resetBrowHide() } }
    }
    /// The eyebrow is raised: at once on hover, but only after a short dwell when it had faded out, as the cue that it opens.
    @Published var browLifted = false
    /// How long the pointer rests on a faded eyebrow before it raises and opens.
    nonisolated static let browRevealDwell: TimeInterval = 0.5
    /// The eyebrow had faded out when the pointer arrived.
    var browRevealing = false

    /// How long the pointer must rest on the collapsed shape before it opens: a faded eyebrow also waits out its dwell.
    nonisolated static func hoverOpenDelay(base: TimeInterval, browRevealing: Bool) -> TimeInterval {
        base + (browRevealing ? browRevealDwell + 0.15 : 0)
    }
    /// The eyebrow has faded out after sitting unused.
    @Published private(set) var browHidden = false
    private var browHideWork: DispatchWorkItem?

    /// Whether the eyebrow is faded out right now: hidden, and no HUD, live activity or sneak peek showing. Idle ears do not keep it up.
    var browFaded: Bool {
        browHidden && !isExpanded && hud.event == nil && !showsLiveActivity && !showsSneakPeek
    }
    private var cancellables: Set<AnyCancellable> = []
    private var sneakPeekWork: DispatchWorkItem?
    private var peekFilter = SneakPeekFilter(launchedAt: .now)
    private var callPeekWork: DispatchWorkItem?

    static let sneakPeekHeight: CGFloat = 24

    init(geometry: NotchGeometry, settings: AppSettings) {
        self.geometry = geometry
        self.settings = settings
        self.hud = HUDCenter(settings: settings)
        self.agentHooks = AgentHooks(board: agents,
                                     isOn: { settings.idleLeft == .agents || settings.idleRight == .agents },
                                     watchesHerdr: { settings.watchesHerdr })
        Publishers.CombineLatest4(nowPlaying.$track.map { $0?.isPlaying == true }, timer.$anchor.map { $0 != nil },
                                  settings.$collapsedMusic, settings.$collapsedTimer)
            .map { music, timer, showMusic, showTimer in (music && showMusic) || (timer && showTimer) }
            .combineLatest(recorder.$startedAt.map { $0 != nil },
                           privacy.$cameraInUse.combineLatest(privacy.$micInUse, settings.$privacyIndicator).map { ($0 || $1) && $2 })
            .map { $0 || $1 || $2 }
            .combineLatest(calls.$call.map { $0 != nil })
            .map { $0 || $1 }
            .combineLatest(downloads.$status.map { $0 != nil }.combineLatest(settings.$collapsedDownloads).map { $0 && $1 })
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] in self?.showsLiveActivity = $0 }
            .store(in: &cancellables)
        nowPlaying.$track
            .sink { [weak self] in self?.lyrics.update(for: $0) }
            .store(in: &cancellables)
        nowPlaying.$track.map { track in track.map { $0.artist.isEmpty ? $0.title : $0.title + "  " + $0.artist } ?? "" }
            .removeDuplicates()
            .combineLatest(lyrics.$lines.map { $0.map(\.text) }.removeDuplicates(), settings.$lyricsEnabled)
            .map { title, lyricLines, lyricsOn in Self.peekLineWidth(lines: [title] + (lyricsOn ? lyricLines : [])) }
            .removeDuplicates()
            .sink { [weak self] in self?.songPeekWidth = $0 }
            .store(in: &cancellables)
        lyrics.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // The ears widen for a download's percent even when another live activity already shows.
        downloads.$status.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        privacy.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        timer.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        calls.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.$noticesTab
            .sink { [weak self] in self?.notices.isEnabled = $0 }
            .store(in: &cancellables)
        // Agents working or waiting, for the closed notch; each herdr session is a source of its own.
        herdr.onStates = { [weak self] socket, panes in
            self?.agents.replace(source: "herdr:\(socket)", with: Herdr.boardAgents(panes))
        }
        // Claude Code sessions anywhere, through its hooks; kept only while the count is shown.
        notifyServer.onAgent = { [agentHooks] in agentHooks.apply($0) }
        settings.$idleLeft.combineLatest(settings.$idleRight)
            .map { $0 == .agents || $1 == .agents }
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.agentHooks.reset() }
            .store(in: &cancellables)
        agents.$counts
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // The tab's badge counts unseen notices.
        notices.$unseen
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        calls.$call
            .sink { [weak self] in self?.callControls.follow($0) }
            .store(in: &cancellables)
        callControls.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // A meeting's name shows under the notch when the call starts.
        calls.$call
            .compactMap { call in call.flatMap { call in call.title.map { "\(call.startedAt)|\($0)" } } }
            .removeDuplicates()
            .sink { [weak self] _ in self?.triggerCallPeek() }
            .store(in: &cancellables)
        nowPlaying.$track
            .compactMap { $0.map { "\($0.identity)|\($0.isPlaying)" } }
            .filter { [weak self] in self?.peekFilter.shouldPeek($0, at: .now) ?? false }
            .sink { [weak self] _ in self?.triggerSneakPeek() }
            .store(in: &cancellables)
        hud.$event
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        appMenus.$frames
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // The idle ears show these. AI limits refresh every 20 s, so only a limit becoming known or unknown,
        // which resizes the notch, reaches the whole view; IdleEars watches the values itself.
        hud.$power.map { _ in () }
            .merge(with: weather.$current.map { _ in () },
                   aiUsage.$providers.combineLatest(settings.$idleAIWindow)
                       .map { providers, window in [IdleItem.claude, .codex].map { Self.aiLeft($0, in: providers, window: window) != nil } }
                       .removeDuplicates().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.leaveHiddenTab() }
            .store(in: &cancellables)
        settings.$hiddenCalendarIDs
            .sink { [weak self] in self?.calendar.hiddenCalendarIDs = Set($0) }
            .store(in: &cancellables)
        calendar.onUpcoming = { [weak self] item in
            // With a video-call link, clicking the notice joins the meeting; otherwise it opens the notch as before.
            let join = item.joinURL.map { url in { _ = NSWorkspace.shared.open(url) } }
            let shown = self?.hud.showLasting(duration: CalendarModel.alertSpacing, action: join) { [weak self] in
                // When it comes back after another HUD: only if alerts are still on, the event is still there
                // and not well under way.
                guard let self, self.calendar.stillAlerts(item) else { return nil }
                return .notice(symbol: item.joinURL == nil ? "calendar" : "video.fill", title: item.title,
                               detail: Self.upcomingDetail(item))
            }
            // Kept only when it actually showed; coming back after another HUD doesn't add it again.
            if shown == true {
                self?.notices.add(symbol: item.joinURL == nil ? "calendar" : "video.fill", title: item.title,
                                  detail: Self.upcomingDetail(item), action: join)
            }
        }
        settings.$eventAlerts.combineLatest(settings.$calendarEnabled)
            .map { $0 && $1 }
            .sink { [weak self] in self?.calendar.alertsEnabled = $0 }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// "in 5 minutes", and "in 5 minutes · Click to join" when the event has a meeting link.
    static func upcomingDetail(_ item: CalendarItem) -> String {
        let when = item.start.formatted(.relative(presentation: .named))
        return item.joinURL == nil ? when : "\(when) · \(String(localized: "Click to join"))"
    }

    var expandedSize: CGSize {
        var width = settings.expandedWidth
        if settings.widenForTabs { width = Self.widened(width, fitting: widthFittingTabs, limit: geometry.maxExpandedWidth) }
        return CGSize(width: width, height: settings.expandedHeight)
    }

    /// The saved width, or the width that shows every tab when that is more, but never past the panel.
    nonisolated static func widened(_ width: CGFloat, fitting: CGFloat, limit: CGFloat) -> CGFloat {
        max(width, min(fitting, limit))
    }

    nonisolated static let tabSlot: CGFloat = 36
    /// Horizontal inset of the expanded content from the shape's edge.
    nonisolated static let headerInset: CGFloat = 18 + 14

    /// Battery, weather, Settings and Quit at the right end of the header.
    var headerStatusWidth: CGFloat {
        Self.headerStatusWidth(battery: settings.batteryInHeader && hud.power != nil,
                               weather: settings.headerWeather && weather.current != nil)
    }

    nonisolated static func headerStatusWidth(battery: Bool, weather: Bool) -> CGFloat {
        var width: CGFloat = 2 * (26 + 6)
        if battery { width += 66 }
        if weather { width += 50 }
        return width
    }

    /// The width of a row of `count` tab buttons.
    nonisolated static func stripWidth(_ count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * tabSlot - 6 : 0
    }

    /// On notched displays the tabs sit on both sides of the camera: the first `left` on the left, the rest on the right
    /// ahead of the status icons. Picks the split that keeps the wider side narrowest; `side` is that side's width.
    /// A tab strip's frame is 2 points wider than its buttons.
    nonisolated static func tabSplit(count: Int, status: CGFloat) -> (left: Int, side: CGFloat) {
        var best = (left: count, side: CGFloat.infinity)
        // From the left so a tie keeps more tabs on the left.
        for left in stride(from: count, through: 0, by: -1) {
            let right = count - left
            let side = max(stripWidth(left) + 2, right > 0 ? stripWidth(right) + 2 + status : status)
            if side < best.side { best = (left, side) }
        }
        return best
    }

    /// The width that shows every tab without scrolling: split around the camera on notched displays, otherwise in one row.
    private var widthFittingTabs: CGFloat {
        Self.fittingWidth(tabCount: settings.visibleTabs.count, status: headerStatusWidth,
                          hasNotch: geometry.hasNotch, notchWidth: geometry.collapsedSize.width)
    }

    nonisolated static func fittingWidth(tabCount count: Int, status: CGFloat, hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
        let content: CGFloat
        if hasNotch {
            let side = tabSplit(count: count, status: status).side
            content = 2 * side + notchWidth + 8 + 12
        } else {
            content = stripWidth(count) + 12 + status
        }
        return content + 2 * headerInset
    }

    /// The meeting name the sneak peek shows instead of the track while a call starts.
    var sneakPeekCallTitle: String? {
        callPeekPending ? calls.call?.title : nil
    }

    var showsSneakPeek: Bool {
        Self.showsSneakPeek(enabled: settings.sneakPeekEnabled, callTitle: sneakPeekCallTitle,
                            track: nowPlaying.track.map { $0.isPlaying },
                            lyricsLive: settings.lyricsEnabled && settings.lyricsUnderNotch && !lyrics.lines.isEmpty,
                            always: settings.sneakPeekAlways, pending: sneakPeekPending)
    }

    /// `track` is whether the loaded track plays, nil without one. `lyricsLive` says lyrics are on, shown under the
    /// notch and known for this song; they only count while it plays.
    nonisolated static func showsSneakPeek(enabled: Bool, callTitle: String?, track: Bool?, lyricsLive: Bool,
                                           always: Bool, pending: Bool) -> Bool {
        guard enabled else { return false }
        if callTitle != nil { return true }
        guard let playing = track else { return false }
        return always || pending || (lyricsLive && playing)
    }

    /// While music plays, the collapsed notch grows an "ear" on each side
    /// for the artwork and a playback indicator, plus a text line underneath
    /// while the sneak peek shows.
    static let hudEarWidth: CGFloat = 102
    /// Room for a short value such as "73%" or "16°" on each side while idle.
    static let idleEarWidth: CGFloat = 70

    /// On a display without a notch the sneak peek or lyric sits between the artwork and the visualizer, not in a row below.
    var sneakPeekInline: Bool { !geometry.hasNotch && showsSneakPeek }
    /// The line's room when it sits inline: the song's longest lyric, or its title and artist, measured once per song so
    /// the shape doesn't resize with every line. A call that is starting is measured on its own.
    @Published private(set) var songPeekWidth: CGFloat = NotchViewModel.minInlinePeekWidth
    nonisolated static let minInlinePeekWidth: CGFloat = 240

    /// What the inline line may take, at most a third of the screen; anything longer shrinks a little, then truncates.
    var inlinePeekWidth: CGFloat {
        let wanted = sneakPeekCallTitle.map { Self.peekLineWidth(lines: [$0]) } ?? songPeekWidth
        return Self.clampedPeekWidth(wanted, screenWidth: geometry.screenFrame.width)
    }

    nonisolated static func clampedPeekWidth(_ wanted: CGFloat, screenWidth: CGFloat) -> CGFloat {
        min(max(wanted, minInlinePeekWidth), screenWidth / 3)
    }

    /// The widest of these lines as SneakPeekLine draws them: the play symbol and its gap, the text, and the side padding.
    nonisolated static func peekLineWidth(lines: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let text = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(8 + 6 + text + 2 * 10)
    }

    /// On a display without a notch every HUD is one line: the symbol beside its text, level bar or percent.
    var hudSingleRow: Bool {
        guard !geometry.hasNotch, let event = hud.event else { return false }
        return HUDContent.line(for: event) != nil || HUDContent.compactValueWidth(for: event) != nil
    }

    var collapsedSize: CGSize {
        Self.collapsedSize(base: geometry.collapsedSize, hasNotch: geometry.hasNotch, screenWidth: geometry.screenFrame.width,
                           event: hud.event, showsLiveActivity: showsLiveActivity, earWidth: earWidth,
                           idleGrowth: showsIdleEars ? (idleFittedSides.map { $0.left + $0.right } ?? 2 * Self.idleEarWidth) : nil,
                           showsSneakPeek: showsSneakPeek, inlinePeekWidth: inlinePeekWidth)
    }

    /// The closed shape's size from the display's own (`base`) and what the notch shows. `idleGrowth` is how much the
    /// idle values add, nil when there are none.
    static func collapsedSize(base: CGSize, hasNotch: Bool, screenWidth: CGFloat, event: HUDEvent?,
                              showsLiveActivity: Bool, earWidth: @autoclosure () -> CGFloat,
                              idleGrowth: @autoclosure () -> CGFloat?, showsSneakPeek: Bool,
                              inlinePeekWidth: @autoclosure () -> CGFloat) -> CGSize {
        var size = base
        if !hasNotch, let event, let value = HUDContent.compactValueWidth(for: event) {
            size.width = max(size.width, 2 * 18 + HUDContent.lineSymbolWidth + HUDContent.lineGap + value)
            return size
        }
        if !hasNotch, let event, let line = HUDContent.line(for: event) {
            // Nothing hides in the middle, so a notice or headphone battery is one line.
            // The symbol, the gap after it and the side padding, then the text; long lines truncate at a third of the screen.
            let text = ceil((line as NSString).size(withAttributes: [.font: HUDContent.lineFont]).width)
            let content = HUDContent.lineSymbolWidth + HUDContent.lineGap + text
            size.width = min(max(size.width, 2 * 18 + content), max(size.width, screenWidth / 3))
            return size
        }
        if let event {
            size.width += 2 * hudEarWidth
            switch event {
            case .headphones, .notice: size.height += sneakPeekHeight
            default: break
            }
            return size
        }
        let sneakPeekInline = !hasNotch && showsSneakPeek
        if showsLiveActivity {
            size.width += 2 * earWidth()
        } else if !sneakPeekInline, let growth = idleGrowth() {
            size.width += growth
        }
        if sneakPeekInline {
            size.width = max(size.width, (showsLiveActivity ? 2 * earWidth() : 0) + inlinePeekWidth() + 2 * 13)
        } else if showsSneakPeek {
            size.width = max(size.width, 300)
            size.height += sneakPeekHeight
        }
        return size
    }

    #if DEBUG
    /// `--hide-left-ear` acts as if the app's menus always reached the left ear.
    private static let forcesLeftEarHidden = CommandLine.arguments.contains("--hide-left-ear")
    #endif

    /// True when the collapsed notch's left side would cover the frontmost app's menus. It then grows to the right only,
    /// and what the left side showed moves to the right of the camera. Left as is when the menus reach the right side too.
    var hidesLeftEar: Bool {
        // The inline peek is centred on the line, so it can't make room for the menus by growing right only.
        if sneakPeekInline { return false }
        let notch = geometry.collapsedSize.width
        let width = collapsedSize.width
        guard width > notch else { return false }
        #if DEBUG
        if Self.forcesLeftEarHidden { return true }
        #endif
        // Fitted idle values may grow the left side by less than half; growing right only takes all of it.
        let ear = idleFittedSides?.left ?? (width - notch) / 2
        return Self.menusReachLeftEar(menus: appMenus.frames, screen: geometry.screenFrame, notch: notch, width: width, ear: ear)
    }

    /// Menus whose centre is off the screen belong to another display and are ignored.
    nonisolated static func menusReachLeftEar(menus: [CGRect], screen: CGRect, notch: CGFloat, width: CGFloat, ear: CGFloat) -> Bool {
        guard width > notch else { return false }
        let menus = menus.filter { screen.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let left = screen.midX - notch / 2, right = screen.midX + notch / 2
        let covers = { (from: CGFloat, to: CGFloat) in menus.contains { $0.maxX > from && $0.minX < to } }
        return covers(left - ear, left) && !covers(right, right + width - notch)
    }

    /// The room the eyebrow's stroke leaves at each end of its frame, which fitted idle values keep from the wall too.
    static let idleFittedMargin: CGFloat = 10

    /// On a display without a notch, the idle values size the shape to fit them instead of taking a fixed ear each.
    var idleFits: Bool {
        !geometry.hasNotch && hud.event == nil && !showsLiveActivity && !showsSneakPeek && showsIdleEars
    }

    private var idleFittedSides: (left: CGFloat, right: CGFloat)? {
        guard idleFits else { return nil }
        return Self.idleFittedSides(left: idleValue(settings.idleLeft), right: idleValue(settings.idleRight))
    }

    /// How far fitted idle values grow the shape on each side: each by its own value, nothing where there is none.
    /// The shape then moves sideways so the eyebrow stays over the camera (see `collapsedShift`).
    nonisolated static func idleFittedSides(left: IdleValue?, right: IdleValue?) -> (left: CGFloat, right: CGFloat)? {
        guard left != nil || right != nil else { return nil }
        return (left.map(idleEarWidth(for:)) ?? 0, right.map(idleEarWidth(for:)) ?? 0)
    }

    /// How far one fitted value needs the shape to grow: the value as IdleEars draws it and 8 between it and the
    /// eyebrow's stroke. Its margin from the wall is the one the stroke leaves empty at the end facing it, so the two
    /// cancel out.
    nonisolated static func idleEarWidth(for value: IdleValue) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let text = (value.text as NSString).size(withAttributes: [.font: font]).width
        let symbol = value.symbol
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) }
            .map { $0.size.width + 3 } ?? 0
        return ceil(symbol + text) + 8
    }

    /// How far right the collapsed shape moves: so its left edge stays at the camera's when the left ear is hidden, or
    /// so the eyebrow stays over the camera when fitted idle values grow the two sides by different amounts.
    var collapsedShift: CGFloat {
        Self.collapsedShift(fitted: idleFittedSides, hidesLeftEar: hidesLeftEar,
                            width: collapsedSize.width, notch: geometry.collapsedSize.width)
    }

    nonisolated static func collapsedShift(fitted: (left: CGFloat, right: CGFloat)?, hidesLeftEar: Bool,
                                           width: CGFloat, notch: CGFloat) -> CGFloat {
        // A single side never reaches left of the camera, so only two sides make room for the menus.
        if let fitted, !(fitted.left > 0 && fitted.right > 0 && hidesLeftEar) { return (fitted.right - fitted.left) / 2 }
        return hidesLeftEar ? (width - notch) / 2 : 0
    }

    /// How far the eyebrow's frame sits from the collapsed shape's left wall, which keeps it over the camera.
    nonisolated static func browLead(width: CGFloat, notch: CGFloat, shift: CGFloat) -> CGFloat {
        max(0, (width - notch) / 2 - shift)
    }

    /// Where fitted idle values start past the shape's left wall, besides their margin: just past the eyebrow when it
    /// sits at that wall with room after it (the left ear hidden, or a right side only), otherwise at the wall.
    nonisolated static func idleLead(browLead: CGFloat, shift: CGFloat, notch: CGFloat) -> CGFloat {
        browLead < 0.5 && shift > 0 ? notch - idleFittedMargin + 8 - idleFittedMargin : 0
    }

    /// The collapsed shape on screen.
    var collapsedRect: NSRect {
        Self.collapsedRect(geometry: geometry, size: collapsedSize, shift: collapsedShift)
    }

    static func collapsedRect(geometry: NotchGeometry, size: CGSize, shift: CGFloat) -> NSRect {
        var rect = geometry.shapeRect(size: size).offsetBy(dx: shift, dy: 0)
        // The gap above a floating eyebrow still counts, so flicking the pointer to the screen edge finds it.
        rect.size.height += geometry.topInset
        // The bare eyebrow is small, so the pointer may be a little off to the side.
        if !geometry.hasNotch && size.width == geometry.collapsedSize.width { rect = rect.insetBy(dx: -8, dy: 0) }
        return rect
    }

    /// Shows the eyebrow and starts counting down to hiding it again. It only hides while nothing else shows in the collapsed shape.
    func resetBrowHide() {
        browHidden = false
        browHideWork?.cancel()
        browHideWork = nil
        guard settings.autoHideBrow, !geometry.hasNotch else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.browHideWork = nil
                let idle = !self.isExpanded && !self.pointerOverCollapsed && self.hud.event == nil
                    && !self.showsLiveActivity && !self.showsSneakPeek
                if idle { self.browHidden = true } else { self.resetBrowHide() }
            }
        }
        browHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.browHideDelay, execute: work)
    }

    private func triggerSneakPeek() {
        sneakPeekWork?.cancel()
        sneakPeekPending = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sneakPeekPending = false }
        }
        sneakPeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.sneakPeekDuration, execute: work)
    }

    private func triggerCallPeek() {
        callPeekWork?.cancel()
        callPeekPending = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.callPeekPending = false }
        }
        callPeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.sneakPeekDuration, execute: work)
    }

    var earWidth: CGFloat {
        let needsText = (timer.isRunning && settings.collapsedTimer) || recorder.isRecording
            || (downloads.status != nil && settings.collapsedDownloads)
        return Self.earWidth(height: geometry.collapsedSize.height, compact: settings.compactLiveActivity,
                             inCall: calls.call != nil, muted: callControls.state?.mic == .off, needsText: needsText)
    }

    nonisolated static func earWidth(height: CGFloat, compact: Bool, inCall: Bool, muted: Bool, needsText: Bool) -> CGFloat {
        let base = compact ? height * 0.7 : height + 6
        // Room for "1:23:45" during a call, plus a mic-slash while muted, and "12:34" when a timer is running or "100%" for a download.
        if inCall { return max(base, muted ? 74 : 60) }
        return needsText ? max(base, 50) : base
    }

    var currentSize: CGSize {
        isExpanded ? expandedSize : collapsedSize
    }

    /// Home for a tab the settings no longer show.
    nonisolated static func visibleTab(_ tab: NotchTab, isVisible: (NotchTab) -> Bool) -> NotchTab {
        isVisible(tab) ? tab : .home
    }

    private func leaveHiddenTab() {
        let next = Self.visibleTab(tab, isVisible: settings.isVisible)
        if next != tab { tab = next }
    }

    /// The tab the notch shows after closing: never Mirror, which would start the camera when it reopens, and never
    /// one that is hidden.
    nonisolated static func tabAfterCollapse(_ tab: NotchTab, isVisible: (NotchTab) -> Bool) -> NotchTab {
        visibleTab(tab == .mirror ? .home : tab, isVisible: isVisible)
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        resetBrowHide()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        resetBrowHide()
        pinned = false
        // The camera must only start from an explicit click on the Mirror tab.
        // Search opened by its shortcut may be a tab the header doesn't show.
        let next = Self.tabAfterCollapse(tab, isVisible: settings.isVisible)
        if next != tab { tab = next }
    }
}

/// Which now-playing changes show the sneak peek. A track already loaded when the app starts, playing or paused,
/// is not news, so the first one seen shortly after launch only becomes the baseline; every later change peeks.
struct SneakPeekFilter {
    /// The first track can take a moment to arrive: the helper starts and the players are asked over AppleScript.
    static let launchWindow: TimeInterval = 5

    let launchedAt: Date
    private var last: String?

    init(launchedAt: Date) {
        self.launchedAt = launchedAt
    }

    /// `key` identifies the track and whether it plays.
    mutating func shouldPeek(_ key: String, at date: Date) -> Bool {
        defer { last = key }
        guard key != last else { return false }
        return last != nil || date.timeIntervalSince(launchedAt) > Self.launchWindow
    }
}
