import Foundation

/// What a release brings, shown once in the notch the first time the app opens after an update to it.
/// A fresh install gets the tour instead, and a release without notes here shows nothing.
enum WhatsNew {
    struct Item: Equatable {
        let symbol: String
        let title: String
        let detail: String
    }

    struct Notes: Equatable {
        let version: String
        let title: String
        let text: String
        let items: [Item]
    }

    /// The last version whose notes were shown, or that was installed fresh.
    nonisolated static let seenKey = "whatsNewSeenVersion"

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A pre-release ("0.35.0-beta.1") shows the notes of the release it leads to.
    static func notes(for version: String) -> Notes? {
        switch version.split(separator: "-").first.map(String.init) ?? version {
        case "0.37.0":
            Notes(version: version, title: String(localized: "Now with papers"),
                  text: String(localized: "Nunsseop \(version) is signed and notarized by Apple, and its bottom edge sits a little closer."),
                  items: [Item(symbol: "checkmark.seal", title: String(localized: "Notarized by Apple"),
                               detail: String(localized: "Opens like any other app, no workarounds")),
                          Item(symbol: "hand.raised", title: String(localized: "Ask again, once"),
                               detail: String(localized: "macOS may want permissions renewed"))])
        case "0.36.0":
            Notes(version: version, title: String(localized: "A little shy now"),
                  text: String(localized: "Nunsseop \(version) steps aside for Mission Control, and can stay on one display."),
                  items: [Item(symbol: "rectangle.3.group", title: String(localized: "Hides in Mission Control"),
                               detail: String(localized: "Out of the way while your windows spread out")),
                          Item(symbol: "display.2", title: String(localized: "Stays on one display"),
                               detail: String(localized: "Turn off following in Settings › Display"))])
        case "0.35.0":
            Notes(version: version, title: String(localized: "Now with feelings"),
                  text: String(localized: "Nunsseop \(version) wears its mood on its brow. Also new: a Monday recap, more shortcuts and six more agents."),
                  items: [Item(symbol: "face.smiling", title: String(localized: "A brow with moods"),
                               detail: String(localized: "Raised when an agent waits, a hop when it's done")),
                          Item(symbol: "list.bullet.rectangle", title: String(localized: "What your agents are doing"),
                               detail: String(localized: "Their last step, and the diff a click away"))])
        case "0.34.0":
            Notes(version: version, title: String(localized: "Freshly groomed"),
                  text: String(localized: "Nunsseop \(version) brings two new things, and there's nothing to set up."),
                  items: [Item(symbol: "gauge.with.dots.needle.67percent", title: String(localized: "Limit alerts"),
                               detail: String(localized: "A nudge at \(LimitAlerts.share(80)) and \(LimitAlerts.share(95)), a cheer at the reset")),
                          Item(symbol: "text.bubble", title: String(localized: "This, once per update"),
                               detail: String(localized: "Says what's new, then gets out of your way"))])
        default:
            nil
        }
    }

    /// The notes to show at this launch: after an update to a version that has some and that hasn't shown them yet.
    static func pending(freshInstall: Bool, version: String, defaults: UserDefaults) -> Notes? {
        guard !freshInstall, defaults.string(forKey: seenKey) != version else { return nil }
        return notes(for: version)
    }
}
