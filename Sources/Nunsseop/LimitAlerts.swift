import Foundation

/// Says once when a 5-hour or weekly limit first passes 80% and 95%, and when a limit that got that far resets.
/// The first reading of a limit only sets what has been passed already, so a relaunch doesn't announce it again.
struct LimitAlerts {
    enum Kind: String {
        case session, weekly
    }

    struct Alert: Equatable {
        let family: AIUsageModel.Family
        let kind: Kind
        /// The share passed, or nil when the limit has reset.
        let threshold: Int?
        let resetsAt: Date?
    }

    static let thresholds = [80, 95]
    /// A fall this large between readings is a new window, not one source reading a little lower than another.
    static let resetDrop = 25.0

    private struct Seen {
        var percent: Double
        var resetsAt: Date?
        var passed: Set<Int>
    }

    private var seen: [String: Seen] = [:]
    /// Limits read at least once, so a window that starts again after a reset is announced from nothing.
    private var known: Set<String> = []

    mutating func step(_ providers: [AIUsageModel.Provider], now: Date) -> [Alert] {
        var alerts: [Alert] = []
        for provider in providers {
            guard let family = AIUsageModel.Family(rawValue: provider.id) else { continue }
            for (kind, window) in [(Kind.session, provider.session), (.weekly, provider.weekly)] {
                let key = "\(family.rawValue)|\(kind.rawValue)"
                // A reset is told by its time passing, even when no reading comes after it, or by a large fall.
                if let previous = seen[key],
                   previous.resetsAt.map({ $0 <= now }) == true || window.map({ previous.percent - $0.percent >= Self.resetDrop }) == true {
                    if !previous.passed.isEmpty { alerts.append(Alert(family: family, kind: kind, threshold: nil, resetsAt: nil)) }
                    seen[key] = nil
                }
                guard let window else { continue }
                let reached = Self.thresholds.filter { Double($0) <= window.percent }
                var entry = seen[key] ?? Seen(percent: window.percent, resetsAt: window.resetsAt,
                                              passed: known.contains(key) ? [] : Set(reached))
                let new = reached.filter { !entry.passed.contains($0) }
                if let highest = new.max() {
                    alerts.append(Alert(family: family, kind: kind, threshold: highest, resetsAt: window.resetsAt))
                }
                entry.passed.formUnion(new)
                entry.percent = window.percent
                entry.resetsAt = window.resetsAt
                seen[key] = entry
                known.insert(key)
            }
        }
        return alerts
    }

    // MARK: Wording

    static func symbol(_ alert: Alert) -> String {
        switch alert.threshold {
        case nil: "arrow.counterclockwise"
        case let threshold? where threshold >= 95: "gauge.with.dots.needle.100percent"
        default: "gauge.with.dots.needle.67percent"
        }
    }

    static func title(_ alert: Alert) -> String {
        let window = alert.kind == .session ? String(localized: "5-hour") : String(localized: "Weekly")
        guard let threshold = alert.threshold else { return String(localized: "\(alert.family.name) \(window) limit reset") }
        return String(localized: "\(alert.family.name) \(window): \(share(threshold)) used")
    }

    /// "80%", or "80 %" in languages that write a space before it.
    static func share(_ threshold: Int) -> String {
        (Double(threshold) / 100).formatted(.percent)
    }

    static func detail(_ alert: Alert) -> String? {
        guard alert.threshold != nil else { return String(localized: "Ready to use again") }
        return alert.resetsAt.map { String(localized: "Resets \($0.formatted(.relative(presentation: .named)))") }
    }
}
