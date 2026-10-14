import SwiftUI

/// The notices agents, terminals, tools and the calendar sent, so one that was missed (it shows for a few seconds)
/// can still be read and followed. Kept in memory only: agents' messages can hold anything.
@MainActor
final class NoticeLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let symbol: String
        let title: String
        let detail: String?
        /// Going back to where it came from (a terminal tab, a meeting), when it said.
        let action: (() -> Void)?
    }

    static let limit = 30

    @Published private(set) var entries: [Entry] = []
    /// Notices since the tab was last looked at.
    @Published private(set) var unseen = 0
    /// While the tab is on screen, new notices are seen as they arrive.
    var isShowing = false {
        didSet { if isShowing { markSeen() } }
    }

    init() {
        #if DEBUG
        // Debug: --demo-notices fills the tab for checking its layout.
        if CommandLine.arguments.contains("--demo-notices") {
            add(symbol: "calendar", title: "Lunch", detail: "in 5 minutes", at: .now.addingTimeInterval(-3600))
            add(symbol: "terminal", title: "Pi · work", detail: "Finished · refactor the parser", action: {}, at: .now.addingTimeInterval(-900))
            add(symbol: "sparkles", title: "Claude Code", detail: "Claude is waiting for your input", action: {}, at: .now.addingTimeInterval(-60))
        }
        #endif
    }

    /// With the tab hidden nothing is kept, like any feature that's turned off.
    var isEnabled = true {
        didSet { if !isEnabled { clear() } }
    }

    func add(symbol: String, title: String, detail: String?, action: (() -> Void)? = nil, at date: Date = .now) {
        guard isEnabled else { return }
        entries.insert(Entry(date: date, symbol: symbol, title: title, detail: detail, action: action), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        if !isShowing { unseen = min(unseen + 1, Self.limit) }
    }

    func markSeen() { unseen = 0 }

    func remove(_ entry: Entry) { entries.removeAll { $0.id == entry.id } }

    func clear() {
        entries = []
        unseen = 0
    }
}

struct NoticesTab: View {
    @ObservedObject var log: NoticeLog
    @State private var selection = DetailSelection<UUID>()

    var body: some View {
        Group {
            if log.entries.isEmpty {
                Text("Notifications from agents, terminals and your calendar show up here")
                    .font(.system(size: 12)).foregroundStyle(PanelInk.hint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelSplit {
                    PanelList(items: log.entries, selection: $selection) { entry, selected in
                        NoticeRow(entry: entry, selected: selected)
                    }
                } right: {
                    detail
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { log.isShowing = true }
        .onDisappear { log.isShowing = false }
    }

    @ViewBuilder private var detail: some View {
        let shown = selection.current(in: log.entries.map(\.id)).flatMap { id in log.entries.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            if let shown {
                HStack(spacing: 10) {
                    Image(systemName: shown.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: shown.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(verbatim: Self.when(shown.date)).font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1)
                    }
                }
                if let detail = shown.detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let shown {
                    PanelAction(title: "Go to source", symbol: "arrow.uturn.right", style: .primary,
                                reason: shown.action == nil ? String(localized: "This notification has no source to go to") : nil) { shown.action?() }
                    PanelAction(title: "Remove", symbol: "xmark") { log.remove(shown) }
                }
                Spacer(minLength: 0)
                PanelAction(title: "Clear all") { log.clear() }
            }
        }
        .padding(.vertical, 2)
    }

    /// "09:41 · 3 minutes ago", with the day too when it was not today.
    private static func when(_ date: Date) -> String {
        let clock = Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month().day().hour().minute())
        return "\(clock) · \(date.panelAgo)"
    }
}

private struct NoticeRow: View {
    let entry: NoticeLog.Entry
    let selected: Bool

    var body: some View {
        LedgerRow(selected: selected) {
            LedgerLine(symbol: entry.symbol, title: entry.title, trailing: entry.date.formatted(.dateTime.hour().minute()))
        }
        // A notice that leads somewhere goes there again; the others just stay readable.
        .onTapGesture { entry.action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.action == nil ? [] : .isButton)
        .help(entry.action == nil ? Text(verbatim: "") : Text("Go to where it came from"))
    }
}
