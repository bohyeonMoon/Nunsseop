import AppKit
import Combine

/// The weekly recap card: read in the background the first time the notch opens in a week whose recap hasn't been shown, then shown once
/// in place of the tab. The AI tab shows it again whenever asked. Last week's logs don't change, so a week is read once.
@MainActor
final class RecapCard: ObservableObject {
    enum Saved: Equatable {
        case saved(URL)
        case failed
    }

    nonisolated static let seenKey = "recapSeenWeek"
    nonisolated static let feedbackSeconds = 4.0

    @Published private(set) var isShowing = false
    @Published private(set) var isReading = false
    @Published private(set) var recap: WeekRecap?
    @Published private(set) var saved: Saved?

    private let defaults: UserDefaults
    private let downloads: URL
    private let read: @Sendable (Date) -> WeekRecap
    private let reveal: (URL) -> Void
    private var readKey: String?

    init(defaults: UserDefaults = .standard,
         downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"),
         read: @escaping @Sendable (Date) -> WeekRecap = { WeekRecap.read(home: URL(fileURLWithPath: NSHomeDirectory()), now: $0) },
         reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.defaults = defaults
        self.downloads = downloads
        self.read = read
        self.reveal = reveal
    }

    /// The Monday that ends the recap's week, as "2026-10-19": the recap is due again from every Monday on.
    nonisolated static func weekKey(now: Date, calendar: Calendar = .current) -> String {
        let monday = WeekRecap.weekStart(of: now, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Showing

    /// The notch opened: shows the recap if this week's is due, once it has been read and the notch is free for it (`canShow`).
    /// A week without sessions has nothing to show and counts as shown.
    func notchOpened(enabled: Bool, canShow: @escaping () -> Bool, now: Date = .now) {
        let key = Self.weekKey(now: now)
        guard enabled, defaults.string(forKey: Self.seenKey) != key, !isShowing else { return }
        load(now: now, key: key) { [self] recap in
            guard defaults.string(forKey: Self.seenKey) != key else { return }
            if recap.isEmpty {
                defaults.set(key, forKey: Self.seenKey)
            } else if canShow() {
                present(key: key)
            }
        }
    }

    /// The AI tab's button: the recap whatever the setting and whether it was shown before.
    func show(now: Date = .now) {
        let key = Self.weekKey(now: now)
        present(key: key)
        load(now: now, key: key) { _ in }
    }

    func close() {
        isShowing = false
        saved = nil
    }

    private func present(key: String) {
        defaults.set(key, forKey: Self.seenKey)
        saved = nil
        isShowing = true
    }

    private func load(now: Date, key: String, then finish: @escaping (WeekRecap) -> Void) {
        if let recap, readKey == key {
            finish(recap)
            return
        }
        guard !isReading else { return }
        isReading = true
        let read = read
        Task.detached(priority: .utility) {
            let recap = read(now)
            await MainActor.run {
                self.recap = recap
                self.readKey = key
                self.isReading = false
                finish(recap)
            }
        }
    }

    // MARK: Saving

    /// Writes the image to Downloads and shows it in Finder; the panel never activates, so there is no save dialog to ask where.
    func saveImage(now: Date = .now) {
        guard let recap, !recap.isEmpty else { return }
        let result: Saved
        if let data = RecapImage.png(recap), let url = try? RecapImage.write(data, to: downloads, now: now) {
            reveal(url)
            result = .saved(url)
        } else {
            result = .failed
        }
        saved = result
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackSeconds) { [weak self] in
            MainActor.assumeIsolated { if self?.saved == result { self?.saved = nil } }
        }
    }
}
