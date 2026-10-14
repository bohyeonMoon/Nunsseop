import AppKit
import SwiftUI

/// Countdown, Pomodoro and stopwatch. Only one runs at a time.
@MainActor
final class TimerModel: ObservableObject {
    enum Mode: String, CaseIterable { case countdown, pomodoro, stopwatch }
    enum Phase { case work, rest }

    @Published var mode: Mode = .countdown { didSet { if mode != oldValue { reset() } } }
    @Published var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: "countdownSeconds") }
    }
    @Published var workMinutes: Int {
        didSet { defaults.set(workMinutes, forKey: "pomodoroWorkMinutes") }
    }
    @Published var restMinutes: Int {
        didSet { defaults.set(restMinutes, forKey: "pomodoroRestMinutes") }
    }
    @Published private(set) var phase: Phase = .work
    @Published private(set) var completedPomodoros = 0
    /// Countdown and Pomodoro: when the current run ends. Stopwatch: when it was (re)started.
    @Published private(set) var anchor: Date?
    /// Time left (countdown) or elapsed (stopwatch) while paused.
    @Published private(set) var pausedValue: TimeInterval?

    private static func stored(_ key: String, _ fallback: Int, in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    private let defaults: UserDefaults
    private let cal: Calendar
    private let now: () -> Date
    private let chime: () -> Void
    /// The day `completedPomodoros` counts.
    private var countedDay: Date
    private var dayObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = { .now },
         chime: @escaping () -> Void = { NSSound(named: "Glass")?.play() }) {
        self.defaults = defaults
        cal = calendar
        self.now = now
        self.chime = chime
        countedDay = calendar.startOfDay(for: now())
        countdownSeconds = Self.stored("countdownSeconds", 5 * 60, in: defaults)
        workMinutes = Self.stored("pomodoroWorkMinutes", 25, in: defaults)
        restMinutes = Self.stored("pomodoroRestMinutes", 5, in: defaults)
        // Timers don't count time asleep, so the day is checked again on wake and clock changes too.
        dayObservers = [
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rollDay() }
            },
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rollDay() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rollDay() }
            },
        ]
    }

    var onFinished: ((String) -> Void)?
    private var ticker: Timer?

    /// Starts the Pomodoro count over when the day has changed since it began.
    func rollDay() {
        let current = cal.startOfDay(for: now())
        guard current != countedDay else { return }
        countedDay = current
        completedPomodoros = 0
    }

    /// Counts a work session for the day it was due, which is earlier than today when the Mac slept through midnight.
    func recordCompletedPomodoro(dueAt due: Date) {
        rollDay()
        guard cal.startOfDay(for: due) == countedDay else { return }
        completedPomodoros += 1
    }

    var isRunning: Bool { anchor != nil }
    var isActive: Bool { anchor != nil || pausedValue != nil }

    /// Seconds left for countdown modes, seconds elapsed for the stopwatch.
    func value(at date: Date? = nil) -> TimeInterval {
        let date = date ?? now()
        switch mode {
        case .stopwatch:
            if let anchor { return (pausedValue ?? 0) + date.timeIntervalSince(anchor) }
            return pausedValue ?? 0
        case .countdown, .pomodoro:
            if let anchor { return max(0, anchor.timeIntervalSince(date)) }
            return pausedValue ?? fullLength
        }
    }

    var fullLength: TimeInterval {
        switch mode {
        case .countdown: return TimeInterval(countdownSeconds)
        case .pomodoro: return TimeInterval((phase == .work ? workMinutes : restMinutes) * 60)
        case .stopwatch: return 0
        }
    }

    func start() {
        guard anchor == nil else { return }
        switch mode {
        case .stopwatch:
            anchor = now()
        case .countdown, .pomodoro:
            anchor = now().addingTimeInterval(pausedValue ?? fullLength)
            pausedValue = nil
        }
        startTicking()
    }

    func pause() {
        guard anchor != nil else { return }
        pausedValue = value()
        anchor = nil
        ticker?.invalidate()
    }

    func reset() {
        anchor = nil
        pausedValue = nil
        phase = .work
        ticker?.invalidate()
    }

    /// The length can be changed only while nothing is running or paused.
    var canEditLength: Bool { mode != .stopwatch && !isActive }

    /// Picks which Pomodoro phase to edit and start from.
    func selectPhase(_ phase: Phase) {
        guard mode == .pomodoro, !isActive else { return }
        self.phase = phase
    }

    func adjustLength(byMinutes delta: Int) {
        guard canEditLength else { return }
        switch mode {
        case .countdown:
            // Steps snap to whole minutes, so 1:30 goes to 2:00 or 1:00.
            let minutes = (delta > 0 ? countdownSeconds / 60 : (countdownSeconds + 59) / 60) + delta
            countdownSeconds = min(Self.maxCountdown, max(60, minutes * 60))
        case .pomodoro:
            if phase == .work { workMinutes = min(180, max(1, workMinutes + delta)) }
            else { restMinutes = min(60, max(1, restMinutes + delta)) }
        case .stopwatch:
            break
        }
    }

    /// Sets the length from typed text: "90" is 90 minutes, "1:30" is 1 min 30 s, "1:00:00" is an hour.
    /// Pomodoro lengths are rounded to whole minutes. Returns false if the text isn't a length.
    @discardableResult
    func setLength(from text: String) -> Bool {
        guard canEditLength, let seconds = Self.parseLength(text), seconds > 0 else { return false }
        switch mode {
        case .countdown:
            countdownSeconds = min(Self.maxCountdown, seconds)
        case .pomodoro:
            let minutes = max(1, Int((Double(seconds) / 60).rounded()))
            if phase == .work { workMinutes = min(180, minutes) } else { restMinutes = min(60, minutes) }
        case .stopwatch:
            return false
        }
        return true
    }

    static let maxCountdown = 24 * 3600

    nonisolated static func parseLength(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        // Six digits per part is far beyond any real length and keeps the arithmetic from overflowing.
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0.count <= 6 }) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let n = numbers.map { $0! }
        switch n.count {
        case 1: return n[0] * 60
        case 2: return n[1] < 60 ? n[0] * 60 + n[1] : nil
        default: return n[1] < 60 && n[2] < 60 ? n[0] * 3600 + n[1] * 60 + n[2] : nil
        }
    }

    private func startTicking() {
        ticker?.invalidate()
        guard mode != .stopwatch else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 0.05
    }

    func tick() {
        guard let anchor, anchor <= now() else { return }
        chime()
        switch mode {
        case .countdown:
            reset()
            onFinished?(String(localized: "Timer finished"))
        case .pomodoro:
            if phase == .work { recordCompletedPomodoro(dueAt: anchor) }
            let finishedWork = phase == .work
            phase = finishedWork ? .rest : .work
            self.anchor = now().addingTimeInterval(fullLength)
            onFinished?(finishedWork ? String(localized: "Time for a break") : String(localized: "Back to work"))
        case .stopwatch:
            break
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A length with units, so it can't be read as a time of day: "25 min", "1 hr 30 min", "1분 30초".
    /// Each unit is formatted on its own and joined with a space, which avoids the list commas and
    /// "and" some languages put between units. Units follow the app's language, like the words around them,
    /// rather than the system's.
    nonisolated static func lengthLabel(_ seconds: Int,
                                        locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        let parts: [(Int, NSCalendar.Unit)] = [(seconds / 3600, .hour), (seconds / 60 % 60, .minute), (seconds % 60, .second)]
        let shown = parts.filter { $0.0 > 0 }
        return (shown.isEmpty ? [(0, .minute)] : shown).compactMap { value, unit in
            formatter.allowedUnits = unit
            return formatter.string(from: TimeInterval(value) * (unit == .hour ? 3600 : unit == .minute ? 60 : 1))
        }.joined(separator: " ")
    }
}

struct TimerTab: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        GeometryReader { proxy in
            // The clock keeps its width unless the notch is too narrow for the lengths beside it.
            let clock = min(236, max(160, proxy.size.width - 138 - 2 - 2 * 14 - 140))
            HStack(alignment: .top, spacing: 0) {
                ModeList(mode: $timer.mode).frame(width: 138, alignment: .topLeading)
                PanelVLine().padding(.vertical, 2)
                TimerClock(timer: timer).frame(width: clock, alignment: .topLeading).padding(.horizontal, 14)
                PanelVLine().padding(.vertical, 2)
                side.padding(.leading, 14).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: proxy.size.height, alignment: .top)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var side: some View {
        switch timer.mode {
        case .countdown:
            VStack(alignment: .leading, spacing: 0) {
                PanelCaption(String(localized: "Length")).padding(.vertical, 4)
                // Two to a row when the notch is narrow.
                ViewThatFits(in: .horizontal) {
                    presets(perRow: 3)
                    presets(perRow: 2)
                }
            }
        case .pomodoro:
            VStack(alignment: .leading, spacing: 0) {
                PanelCaption(String(localized: "Phase")).padding(.vertical, 4)
                Group {
                    phase(.work, String(localized: "Focus \(TimerModel.lengthLabel(timer.workMinutes * 60))"))
                    phase(.rest, String(localized: "Break \(TimerModel.lengthLabel(timer.restMinutes * 60))"))
                }
                .allowsHitTesting(!timer.isActive)
                Text.panel(String(localized: "Completed today: \(timer.completedPomodoros)"), size: 11, opacity: 0.65, mono: true)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 8).padding(.top, 8)
            }
        case .stopwatch:
            Text("Counts up until you stop it")
                .font(.system(size: 11)).foregroundStyle(PanelInk.hint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private func presets(perRow: Int) -> some View {
        let minutes = [5, 10, 15, 25, 45]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: minutes.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(minutes[start..<min(start + perRow, minutes.count)], id: \.self) { value in
                        LengthChip(title: TimerModel.lengthLabel(value * 60), selected: timer.countdownSeconds == value * 60,
                                   enabled: !timer.isRunning) {
                            timer.reset()
                            timer.countdownSeconds = value * 60
                        }
                    }
                }
            }
        }
    }

    private func phase(_ phase: TimerModel.Phase, _ title: String) -> some View {
        let selected = timer.phase == phase
        return Button { timer.selectPhase(phase) } label: {
            LedgerRow(selected: selected) {
                HStack(spacing: 8) {
                    Circle().fill(selected ? Color.white : .clear).overlay(Circle().stroke(.white.opacity(0.6), lineWidth: selected ? 0 : 1))
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    Text.panel(title, size: 12, weight: .semibold, opacity: selected ? 1 : 0.75).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Timer, Pomodoro or stopwatch, as rows of a list.
private struct ModeList: View {
    @Binding var mode: TimerModel.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelCaption(String(localized: "Mode")).padding(.horizontal, 8).frame(height: 24)
            item(.countdown, "timer", String(localized: "Timer"))
            item(.pomodoro, "target", String(localized: "Pomodoro"))
            item(.stopwatch, "stopwatch", String(localized: "Stopwatch"))
        }
        .padding(.trailing, 10)
    }

    private func item(_ value: TimerModel.Mode, _ symbol: String, _ title: String) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            LedgerRow(selected: selected) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.7)).accessibilityHidden(true)
                    Text.panel(title, size: 12, weight: .semibold, opacity: selected ? 1 : 0.75).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A preset length. Unselected it is bare, like a list row; while a countdown runs they are all dashed, because they do nothing.
private struct LengthChip: View {
    let title: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text.panel(title, size: 11, weight: .semibold, opacity: selected ? 1 : (enabled ? 0.8 : 0.5), mono: true)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 3).frame(minWidth: 42, minHeight: 24)
                .background {
                    if selected { RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)) }
                    else if enabled && hovering { RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)) }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.4), lineWidth: 0.75)
                    } else if !enabled {
                        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The time, a 3 pt bar and the buttons. Stopped, the time is the length: scroll over it or use the buttons beside it to change it
/// a minute at a time (five with Shift), or click it to type a length. Running, it is what is left (or elapsed) and the bar empties;
/// the stopwatch's bar sweeps once a minute.
private struct TimerClock: View {
    @ObservedObject var timer: TimerModel
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let digits: CGFloat = 42

    var body: some View {
        let editable = timer.canEditLength
        let paused = timer.isActive && !timer.isRunning
        VStack(alignment: .leading, spacing: 4) {
            PanelCaption(title).frame(height: 20)
            // Redraws only while running; the bar moves less than a point per step, so it needs no animation.
            TimelineView(.animation(minimumInterval: 0.25, paused: !timer.isRunning)) { context in
                let value = timer.value(at: context.date)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        if timer.isActive || timer.mode == .stopwatch {
                            Text.panel(TimerModel.format(value), size: Self.digits, weight: .semibold, mono: true)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text.panel(caption, size: 12, opacity: 0.6).lineLimit(1)
                        } else {
                            stopped
                            Spacer(minLength: 0)
                            if editable { stepButtons }
                        }
                    }
                    .frame(height: 50, alignment: .bottom)
                    PanelMeter(fraction: progress(value), tint: .white.opacity(paused ? 0.4 : 0.75)).padding(.top, 2)
                }
            }
            HStack(spacing: 6) {
                PanelAction(title: timer.isRunning ? "Pause" : (timer.isActive ? "Resume" : "Start"),
                            symbol: timer.isRunning ? "pause.fill" : "play.fill", style: .primary) {
                    timer.isRunning ? timer.pause() : timer.start()
                }
                PanelAction(title: "Reset", symbol: "arrow.counterclockwise",
                            reason: timer.isActive ? nil : String(localized: "Nothing to reset")) { timer.reset() }
            }
            .padding(.top, 6)
        }
        .padding(.top, 2)
        .onChange(of: editable) { _, isEditable in if !isEditable { editing = false } }
    }

    private var title: String {
        switch timer.mode {
        case .countdown: return "\(String(localized: "Timer")) · \(TimerModel.lengthLabel(Int(timer.fullLength)))"
        case .pomodoro:
            let phase = timer.phase == .work ? String(localized: "Focus") : String(localized: "Break")
            return "\(phase) · \(TimerModel.lengthLabel(Int(timer.fullLength)))"
        case .stopwatch: return String(localized: "Stopwatch")
        }
    }

    private var caption: String {
        if timer.isActive && !timer.isRunning { return String(localized: "Paused") }
        return timer.mode == .stopwatch ? String(localized: "elapsed") : String(localized: "left")
    }

    private func progress(_ value: TimeInterval) -> Double {
        switch timer.mode {
        case .stopwatch: return value.truncatingRemainder(dividingBy: 60) / 60
        case .countdown, .pomodoro: return timer.fullLength > 0 ? min(1, value / timer.fullLength) : 0
        }
    }

    private var stopped: some View {
        ZStack(alignment: .leading) {
            lengthText(TimerModel.lengthLabel(Int(timer.fullLength))).lineLimit(1).minimumScaleFactor(0.5)
                .opacity(editing ? 0 : 1)
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: Self.digits * 0.8, weight: .semibold).monospacedDigit())
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            }
        }
        .overlay {
            if timer.canEditLength && !editing {
                ScrollCatcher(onStep: { timer.adjustLength(byMinutes: $0) }, onClick: startEditing)
            }
        }
        .help(timer.canEditLength ? String(localized: "Scroll or click the time to change it") : "")
    }

    private var stepButtons: some View {
        HStack(spacing: 2) {
            PanelIconButton(symbol: "minus", title: String(localized: "Shorter")) { step(-1) }
            PanelIconButton(symbol: "plus", title: String(localized: "Longer")) { step(1) }
        }
        .opacity(editing ? 0 : 1)
    }

    private func step(_ delta: Int) {
        timer.adjustLength(byMinutes: NSEvent.modifierFlags.contains(.shift) ? delta * 5 : delta)
    }

    /// Numbers large, units small: "25" big with "min" beside it. Lengths with more units get smaller numbers.
    private func lengthText(_ label: String) -> Text {
        let units = label.split(whereSeparator: { !$0.isNumber }).count
        let digitSize = Self.digits * (units >= 3 ? 0.6 : units == 2 ? 0.75 : 1)
        var result = Text("")
        var run = ""
        var runIsDigits = true
        func flush() {
            guard !run.isEmpty else { return }
            result = result + Text(run).font(runIsDigits
                ? .system(size: digitSize, weight: .semibold).monospacedDigit()
                : .system(size: digitSize * 0.4, weight: .semibold))
                .foregroundColor(runIsDigits ? .white : .white.opacity(0.6))
            run = ""
        }
        for character in label {
            let isDigit = character.isNumber
            if isDigit != runIsDigits { flush(); runIsDigits = isDigit }
            run.append(character)
        }
        flush()
        return result
    }

    private func startEditing() {
        // Whole minutes are typed as a plain number, the same way they are read back.
        let seconds = Int(timer.fullLength)
        text = seconds % 60 == 0 ? "\(seconds / 60)" : TimerModel.format(timer.fullLength)
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        timer.setLength(from: text)
        editing = false
    }
}

/// Set while the pointer is over the timer's time, so notch swipes leave that scrolling alone.
@MainActor
enum TimeScrollTarget {
    static var isHovered = false
}

/// Turns scroll-wheel and trackpad scrolling over a view into whole steps: up is +1, down is -1, Shift makes it 5.
private struct ScrollCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onStep = onStep
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onStep = onStep
        view.onClick = onClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        TimeScrollTarget.isHovered = false
    }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        var onClick: (() -> Void)?
        private var accumulated: CGFloat = 0

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { TimeScrollTarget.isHovered = true }
        override func mouseExited(with event: NSEvent) { TimeScrollTarget.isHovered = false }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func scrollWheel(with event: NSEvent) {
            guard event.momentumPhase.isEmpty else { return }
            // Shift turns a mouse wheel into horizontal scrolling, so take whichever axis moved.
            var delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            // Positive means the wheel or fingers moved up, whatever the natural scrolling setting.
            if event.isDirectionInvertedFromDevice { delta = -delta }
            // Trackpads report many small precise deltas; a mouse wheel reports whole lines.
            accumulated += event.hasPreciseScrollingDeltas ? delta / 12 : delta
            let steps = Int(accumulated)
            guard steps != 0 else { return }
            accumulated -= CGFloat(steps)
            onStep?(event.modifierFlags.contains(.shift) ? steps * 5 : steps)
        }
    }
}
