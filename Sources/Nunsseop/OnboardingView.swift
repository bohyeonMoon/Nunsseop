import SwiftUI

/// Every page of the tour sits in one frame, so nothing moves from one step to the next: a header band, a copy column
/// and a visual column that start at the same places on every step, and a footer.
enum OnboardingMetrics {
    /// Between the header band and the content.
    static let bandGap: CGFloat = 8
    static let copyWidth: CGFloat = 204
    static let visualWidth: CGFloat = 344
    /// What the content may take: the notch's height at its smallest, less the band, the gaps and the footer.
    static let contentHeight: CGFloat = 104
    static let rowHeight: CGFloat = 36
    static let iconSize: CGFloat = 28
    static let rowGap: CGFloat = 8
    static let buttonHeight: CGFloat = 28
    static let tabsPerRow = 7
    static let tabRowGap: CGFloat = 6
    static let minimumBand: CGFloat = 32
}

struct OnboardingView: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject var settings: AppSettings
    let hasNotch: Bool
    /// The header band: the camera housing's height, and at least 32.
    let bandHeight: CGFloat
    @StateObject private var login = LaunchAtLogin()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let accent = Color.accentColor.opacity(0.8)
    private static let green = Color(red: 0.31, green: 0.82, blue: 0.47)

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                page
                    .id(tour.index)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            }
            .padding(.top, OnboardingMetrics.bandGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.22), value: tour.index)
        .accessibilityElement(children: .contain)
        .onChange(of: tour.index) { _, index in
            AccessibilityNotification.Announcement(OnboardingText.stepLabel(index + 1, of: OnboardingTour.stepCount)).post()
        }
    }

    // MARK: Frame

    private var header: some View {
        HStack {
            if let news = tour.news {
                Text(String(localized: "What's new in \(news.version)"))
                Spacer()
            } else {
                Text(OnboardingText.title)
                Spacer()
                Text(verbatim: "\(tour.index + 1) / \(OnboardingTour.stepCount)")
                    .monospacedDigit()
                    .accessibilityLabel(OnboardingText.stepLabel(tour.index + 1, of: OnboardingTour.stepCount))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
        .frame(height: bandHeight)
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<(tour.news == nil ? OnboardingTour.stepCount : 0), id: \.self) { i in
                    Capsule().fill(.white.opacity(i == tour.index ? 0.9 : 0.35)).frame(width: i == tour.index ? 16 : 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                if !tour.isLast {
                    Button(OnboardingText.skip) { tour.skip() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.trailing, 8)
                        .frame(height: OnboardingMetrics.buttonHeight)
                } else if tour.step == .agents && tour.rows.count > 1 {
                    compactLogin
                }
                Spacer(minLength: 0)
                if tour.index > 0 { pill(OnboardingText.back, primary: false) { tour.back() } }
                pill(tour.news != nil ? String(localized: "Got it") : tour.isLast ? OnboardingText.done : OnboardingText.next, primary: true) { tour.next() }
            }
        }
        .frame(height: OnboardingMetrics.buttonHeight)
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(primary ? 1 : 0.85))
                .padding(.horizontal, 14)
                .frame(height: OnboardingMetrics.buttonHeight)
                .background(Capsule().fill(primary ? Self.accent : .white.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Pages

    private var page: some View {
        // No spacing of the stack's own: it would be added on both sides of the spacer, and the columns would be 8 points too wide.
        HStack(alignment: .top, spacing: 0) {
            copy.frame(width: OnboardingMetrics.copyWidth, alignment: .topLeading)
            Spacer(minLength: 0)
            visual.frame(width: OnboardingMetrics.visualWidth, alignment: .topLeading)
        }
        .frame(height: OnboardingMetrics.contentHeight, alignment: .top)
    }

    @ViewBuilder private var copy: some View {
        switch tour.step {
        case .opening:
            let opening = OnboardingText.opening(hasNotch: hasNotch,
                                                 hideAfter: settings.autoHideBrow ? Int(settings.browHideDelay.rounded()) : nil)
            CopyColumn(title: OnboardingText.openingTitle, text: opening.text, note: opening.note)
        case .tabs:
            CopyColumn(title: OnboardingText.tabsTitle, text: OnboardingText.tabsText)
        case .filesAndSearch:
            let files = OnboardingText.files(showsSearch: showsSearchRow)
            CopyColumn(title: files.title, text: files.text)
        case .agents:
            CopyColumn(title: OnboardingText.agentsTitle, text: OnboardingText.agentsText, note: OnboardingText.agentsNote)
        case .ready:
            CopyColumn(title: OnboardingText.readyTitle, text: OnboardingText.ready(hasNotch: hasNotch), check: true)
        case .whatsNew:
            CopyColumn(title: tour.news?.title ?? "", text: tour.news?.text ?? "")
        }
    }

    @ViewBuilder private var visual: some View {
        switch tour.step {
        case .opening: openingVisual
        case .tabs: tabsVisual
        case .filesAndSearch: filesVisual
        case .agents: agentsVisual
        case .ready: readyVisual
        case .whatsNew: newsVisual
        }
    }

    private func hint(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(text).lineLimit(1).minimumScaleFactor(0.85)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.65))
    }

    // MARK: Opening and closing

    private var openingVisual: some View {
        HStack(alignment: .top, spacing: 10) {
            MiniScreen(kind: hasNotch ? .notchClosed : .pill,
                       caption: hasNotch ? OnboardingText.closedNotchCaption : OnboardingText.closedPillCaption)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                .frame(height: MiniScreen.height)
                .accessibilityHidden(true)
            MiniScreen(kind: hasNotch ? .open : .openFlat, caption: OnboardingText.openCaption)
        }
    }

    // MARK: Tabs

    private var tabsVisual: some View {
        let tabs = settings.visibleTabs
        let rows = stride(from: 0, to: tabs.count, by: OnboardingMetrics.tabsPerRow).map {
            Array(tabs[$0..<min($0 + OnboardingMetrics.tabsPerRow, tabs.count)])
        }
        return VStack(alignment: .leading, spacing: OnboardingMetrics.rowGap) {
            VStack(spacing: OnboardingMetrics.tabRowGap) {
                ForEach(rows.indices, id: \.self) { r in
                    // Names differ in length, so each row spreads its tabs by their own widths.
                    HStack(spacing: 0) {
                        ForEach(Array(rows[r].enumerated()), id: \.element) { i, tab in
                            if i > 0 { Spacer(minLength: 6) }
                            tabCell(tab)
                        }
                    }
                }
            }
            hint(OnboardingText.tabsHint, symbol: "cursorarrow")
        }
    }

    private func tabCell(_ tab: NotchTab) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tab.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(.white.opacity(0.1)))
                .accessibilityHidden(true)
            Text(tab.title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Files and search

    /// The row for the shortcut is left out when the shortcut is off.
    private var showsSearchRow: Bool { settings.searchHotkey }

    private var filesVisual: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.rowGap) {
            TextRow(symbol: "tray.and.arrow.down", sub: OnboardingText.dropText) {
                Text(OnboardingText.dropTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            if showsSearchRow {
                TextRow(symbol: "magnifyingglass", sub: OnboardingText.searchText) {
                    HStack(spacing: 4) {
                        ForEach(Array(OnboardingTour.keycaps(for: settings.searchHotKey).enumerated()), id: \.offset) { _, key in
                            Keycap(key)
                        }
                        Text(OnboardingText.searchTitle)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.leading, 2)
                    }
                }
            }
        }
    }

    // MARK: Agents

    private var agentsVisual: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.rowGap) {
            toolList
            // With one tool there is room for the login row; with more it goes in the footer.
            if tour.rows.count == 1 { loginRow }
            hint(OnboardingText.reopen)
        }
    }

    @ViewBuilder private var toolList: some View {
        let rows = VStack(spacing: OnboardingMetrics.rowGap) {
            ForEach(tour.rows) { toolRow($0) }
        }
        if tour.rows.count > 2 {
            // Two rows show; the rest scroll.
            ScrollView(.vertical) { rows }
                .scrollIndicators(.never)
                .frame(height: 2 * OnboardingMetrics.rowHeight + OnboardingMetrics.rowGap)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    }
                }
        } else {
            rows
        }
    }

    private func toolRow(_ row: OnboardingTour.ToolRow) -> some View {
        let tool = row.tool
        let note = Self.note(for: row, notificationsOn: settings.localNotifications)
        return HStack(spacing: 10) {
            Text(tool.monogram)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                .frame(width: OnboardingMetrics.iconSize, height: OnboardingMetrics.iconSize)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 4) {
                    if row.state == .connected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Self.green)
                            .accessibilityHidden(true)
                    }
                    Text(note.text)
                        .font(.system(size: 11)).foregroundStyle(note.failed ? Color.red : .white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.state != .connected {
                Button { tour.connect(tool) } label: {
                    Text(note.failed ? OnboardingText.retry : OnboardingText.connect)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14).frame(height: OnboardingMetrics.buttonHeight)
                        .background(Capsule().fill(.white.opacity(0.15)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!settings.localNotifications)
                .accessibilityLabel(OnboardingText.connectLabel(tool.name))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: OnboardingMetrics.rowHeight)
        .surface(RoundedRectangle(cornerRadius: 10))
        .help(note.failed ? note.detail : "")
        .accessibilityElement(children: .contain)
    }

    /// What a tool's row says under its name; `detail` is the whole path of a file that couldn't be changed.
    static func note(for row: OnboardingTour.ToolRow, notificationsOn: Bool) -> (text: String, failed: Bool, detail: String) {
        switch row.state {
        case .connected:
            if row.tool == .codex { return (OnboardingText.connectedTrust, false, "") }
            return (row.backedUp ? OnboardingText.connectedBackedUp : OnboardingText.connected, false, "")
        case .failed(let file):
            return (OnboardingText.couldntChange(file.lastPathComponent), true, file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        case .idle:
            if !notificationsOn { return (OnboardingText.notificationsOff, false, "") }
            return (row.tool == .codex ? OnboardingText.trustHooks : OnboardingText.notConnected, false, "")
        }
    }

    // MARK: What's new

    private var newsVisual: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.rowGap) {
            ForEach(tour.news?.items ?? [], id: \.title) { item in
                InfoRow(symbol: item.symbol, title: item.title, sub: item.detail)
            }
        }
    }

    // MARK: Ready and the login switch

    private var readyVisual: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.rowGap) {
            InfoRow(symbol: "lock", title: OnboardingText.permissionsTitle, sub: OnboardingText.permissionsText)
            loginRow
            hint(OnboardingText.reopen)
        }
    }

    /// What the switch is about: a problem with the login item, or whether it is on.
    private var loginNote: (text: String, color: Color) {
        if let error = login.lastError { return (error, .red) }
        if login.needsApproval { return (OnboardingText.loginNeedsApproval, .orange) }
        if !login.isInApplicationsFolder { return (OnboardingText.loginMoveApp(Bundle.main.bundlePath), .white.opacity(0.65)) }
        return (login.isEnabled ? OnboardingText.loginOn : OnboardingText.loginOff, .white.opacity(0.65))
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { login.isEnabled }, set: { login.set($0) })
    }

    private var loginRow: some View {
        let note = loginNote
        return InfoRow(symbol: "power", title: OnboardingText.login, sub: note.text, subColor: note.color) {
            loginSwitch
        }
        .help(note.text)
        .onAppear { login.refresh() }
    }

    private var loginSwitch: some View {
        Toggle(OnboardingText.login, isOn: loginBinding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .environment(\.colorScheme, .dark)
    }

    /// The agents step has no room for the row, so the footer holds the switch where Skip would be.
    private var compactLogin: some View {
        let note = loginNote
        let problem = login.lastError != nil || login.needsApproval || !login.isInApplicationsFolder
        return HStack(spacing: 6) {
            loginSwitch
            Text(problem ? note.text : OnboardingText.login)
                .font(.system(size: 12)).foregroundStyle(problem ? note.color : .white.opacity(0.65))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .help(note.text)
        .onAppear { login.refresh() }
    }
}

private extension NotifyIntegration {
    /// The app draws no symbol for a tool, so two letters in a rounded square tell the rows apart.
    var monogram: String {
        switch self {
        case .claudeCode: "CC"
        case .codex: "CX"
        case .gemini: "GC"
        case .openCode: "OC"
        case .omp: "OP"
        case .omo: "OM"
        case .pi: "PI"
        }
    }
}

// MARK: - Pieces

private struct CopyColumn: View {
    let title: String
    let text: String
    var note: String?
    var check = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if check {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(Color(red: 0.31, green: 0.82, blue: 0.47)).accessibilityHidden(true)
                }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: OnboardingMetrics.contentHeight, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5).frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// A card with an icon, a title and a line under it, and what goes at its end.
private struct InfoRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let sub: String
    var subColor: Color = .white.opacity(0.65)
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .frame(width: OnboardingMetrics.iconSize, height: OnboardingMetrics.iconSize)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text(sub).font(.system(size: 11)).foregroundStyle(subColor).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: OnboardingMetrics.rowHeight)
        .surface(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(symbol: String, title: String, sub: String) {
        self.init(symbol: symbol, title: title, sub: sub) { EmptyView() }
    }
}

/// An icon, a heading made of anything, and up to two lines under it.
private struct TextRow<Title: View>: View {
    let symbol: String
    let sub: String
    @ViewBuilder let title: Title

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A small desktop with the notch (or the pill) closed or open, and where the pointer is.
private struct MiniScreen: View {
    enum Kind { case notchClosed, pill, open, openFlat }

    let kind: Kind
    let caption: String

    static let width: CGFloat = 152
    static let height: CGFloat = 80

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color(red: 0.20, green: 0.26, blue: 0.36)
                Rectangle().fill(.black.opacity(0.35)).frame(height: 12)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 46, height: 20).offset(x: 14, y: 54)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 58, height: 20).offset(x: 80, y: 54)
                switch kind {
                case .notchClosed:
                    UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(.black)
                        .frame(width: 40, height: 12).offset(x: (Self.width - 40) / 2)
                    pointer(88, 18)
                case .pill:
                    Capsule().fill(.black).frame(width: 44, height: 7).offset(x: (Self.width - 44) / 2, y: 2)
                    pointer(106, 1)
                case .open, .openFlat:
                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black)
                        .frame(width: 104, height: 44).offset(x: (Self.width - 104) / 2)
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(i == 0 ? 0.8 : 0.4)).frame(width: 9, height: 7)
                        }
                    }
                    .frame(width: Self.width).offset(y: 22)
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.22)).frame(width: 80, height: 8)
                        .offset(x: (Self.width - 80) / 2, y: 33)
                    pointer(76, kind == .open ? 3 : 2)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.18), lineWidth: 0.5))
            Text(caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    /// The pointer with its tip at (x, y) in the screen.
    private func pointer(_ x: CGFloat, _ y: CGFloat) -> some View {
        Image(systemName: "cursorarrow").font(.system(size: 14)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 0.5)
            .frame(width: 14, height: 16)
            .offset(x: x - 1, y: y - 1)
    }
}
