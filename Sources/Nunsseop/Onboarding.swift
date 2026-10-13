import AppKit
import Combine

/// The tour that opens the notch on a first launch: which step it is on, whether it still runs, and the tools its
/// last step offers to connect. It lives with the view model, so a notch that closes in the middle comes back to
/// the same step; only finishing or skipping ends it.
@MainActor
final class OnboardingTour: ObservableObject {
    enum Step: Equatable { case opening, tabs, filesAndSearch, agents, ready }

    /// What a key does while the notch shows the tour.
    enum Command: Equatable { case next, back, skip }

    struct ToolRow: Identifiable, Equatable {
        enum State: Equatable {
            case idle, connected
            /// The file that couldn't be changed.
            case failed(URL)
        }

        let tool: NotifyIntegration
        var state: State
        /// Connecting kept the tool's old settings file beside it.
        var backedUp = false

        var id: String { tool.rawValue }
    }

    nonisolated static let doneKey = "onboardingDone"
    nonisolated static let stepCount = 4
    /// The notch opens at least this big while the tour runs, whatever size it is set to: with a header band of 32 points.
    nonisolated static let minimumSize = CGSize(width: 620, height: 196)

    /// The header band is the camera housing's height, and at least 32.
    nonisolated static func band(notchHeight: CGFloat) -> CGFloat { max(notchHeight, OnboardingMetrics.minimumBand) }

    /// The least room the tour has: a taller band takes its extra height from the notch, not from the content.
    nonisolated static func minimumFrame(notchHeight: CGFloat) -> CGSize {
        CGSize(width: minimumSize.width, height: minimumSize.height + band(notchHeight: notchHeight) - OnboardingMetrics.minimumBand)
    }

    @Published private(set) var isActive = false
    @Published private(set) var index = 0
    @Published private(set) var rows: [ToolRow] = []

    /// A first launch that has not started the tour yet.
    private(set) var isPending = false

    private var defaults: UserDefaults
    private var presentTools: () -> [NotifyIntegration]
    private var isConnected: (NotifyIntegration) -> Bool
    private var connectTool: (NotifyIntegration) throws -> Void
    private var hasBackup: (NotifyIntegration) -> Bool

    init(defaults: UserDefaults = .standard,
         presentTools: @escaping () -> [NotifyIntegration] = { NotifyIntegration.allCases.filter(\.isPresent) },
         isConnected: @escaping (NotifyIntegration) -> Bool = { $0.isInstalled },
         connectTool: @escaping (NotifyIntegration) throws -> Void = { try $0.install() },
         hasBackup: @escaping (NotifyIntegration) -> Bool = {
             FileManager.default.fileExists(atPath: $0.configURL.appendingPathExtension("nunsseop-backup").path)
         }) {
        self.defaults = defaults
        self.presentTools = presentTools
        self.isConnected = isConnected
        self.connectTool = connectTool
        self.hasBackup = hasBackup
    }

    // MARK: First run

    /// Whether this launch is the first one on this Mac: the notify token, which the view model's server creates, is not
    /// there yet. Asked before the view model is built.
    nonisolated static func isFreshInstall(tokenFile: URL = NotifyServer.tokenURL) -> Bool {
        !FileManager.default.fileExists(atPath: tokenFile.path)
    }

    /// The tour runs by itself once, on a fresh install. Settings can replay it whatever this says.
    nonisolated static func shouldStart(freshInstall: Bool, defaults: UserDefaults = .standard) -> Bool {
        freshInstall && !defaults.bool(forKey: doneKey)
    }

    func prepare(freshInstall: Bool) {
        isPending = Self.shouldStart(freshInstall: freshInstall, defaults: defaults)
    }

    /// A notice that leads somewhere or a permission prompt is answered first, and nothing opens on a hidden panel.
    nonisolated static func canBegin(panelVisible: Bool, approvalShowing: Bool, noticeClickable: Bool) -> Bool {
        panelVisible && !approvalShowing && !noticeClickable
    }

    // MARK: Steps

    /// The last step offers the tools found on this Mac, or, with none, just says it is done.
    nonisolated static func steps(hasTools: Bool) -> [Step] {
        [.opening, .tabs, .filesAndSearch, hasTools ? .agents : .ready]
    }

    var steps: [Step] { Self.steps(hasTools: !rows.isEmpty) }
    var step: Step { steps[index] }
    var isLast: Bool { index == steps.count - 1 }

    /// Whether the notch shows the tour rather than its tabs. A closed notch shows nothing, and a permission prompt gets the
    /// notch to itself; the tour is still where it was after both.
    func shows(expanded: Bool, approvalShowing: Bool) -> Bool {
        isActive && expanded && !approvalShowing
    }

    func start() {
        rows = presentTools().map { ToolRow(tool: $0, state: isConnected($0) ? .connected : .idle) }
        index = 0
        isPending = false
        isActive = true
    }

    func next() {
        guard isActive else { return }
        if isLast { finish() } else { index += 1 }
    }

    func back() {
        guard isActive, index > 0 else { return }
        index -= 1
    }

    func skip() { finish() }

    func finish() {
        defaults.set(true, forKey: Self.doneKey)
        isPending = false
        isActive = false
    }

    func perform(_ command: Command) {
        switch command {
        case .next: next()
        case .back: back()
        case .skip: skip()
        }
    }

    /// Return and → go on, ← goes back and Escape skips. Not with a modifier held.
    nonisolated static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch Int(keyCode) {
        case 53: return .skip
        case 36, 76, 124: return .next
        case 123: return .back
        default: return nil
        }
    }

    // MARK: Connecting tools

    /// Connects the tool the way Settings does, and keeps a failure to show it.
    func connect(_ tool: NotifyIntegration) {
        guard let i = rows.firstIndex(where: { $0.tool == tool }) else { return }
        do {
            try connectTool(tool)
            rows[i].state = .connected
            rows[i].backedUp = hasBackup(tool)
        } catch {
            rows[i].state = .failed(tool.file(failing: error))
        }
    }

    // MARK: Keys

    /// A shortcut as the keys to press: each modifier, then the key.
    nonisolated static func keycaps(for combo: HotKeyCombo) -> [String] {
        let modifiers = "⌃⌥⇧⌘"
        let label = combo.label
        let leading = label.prefix { modifiers.contains($0) }
        let key = label.dropFirst(leading.count)
        return leading.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }

    /// Debug only: the no-notch pages on a display that has a notch.
    private(set) var showsWithoutNotch = false

    #if DEBUG
    /// Debug: `--demo-onboarding`. Shows a step with made-up tools that connect to nothing and a done flag of its own, so
    /// looking never touches a tool's settings or the real flag.
    func startDemo(step: Int, tools: [NotifyIntegration], connected: Set<NotifyIntegration>, withoutNotch: Bool) {
        defaults = UserDefaults(suiteName: "nunsseop-onboarding-demo") ?? .standard
        presentTools = { tools }
        isConnected = { connected.contains($0) }
        connectTool = { _ in }
        hasBackup = { _ in true }
        showsWithoutNotch = withoutNotch
        start()
        index = min(max(step, 0), Self.stepCount - 1)
    }
    #endif
}
