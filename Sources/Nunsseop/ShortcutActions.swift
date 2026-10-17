import Foundation

/// What a global shortcut can do. Each has a combination of its own, which is empty until the user records one, except Search's.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // The raw value is the start of the keys a combination is saved under (`searchHotKeyCode`, ...), as Search's always were.
    case search, waitingAgent, agentsTab, lastNotice, notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: String(localized: "Open Search in the notch")
        case .waitingAgent: String(localized: "Go to the agent that waits")
        case .agentsTab: String(localized: "Open the Agents tab")
        case .lastNotice: String(localized: "Go to where the last notice came from")
        case .notch: String(localized: "Open or close the notch")
        }
    }

    var subtitle: String? {
        switch self {
        case .waitingAgent: String(localized: "Brings the terminal of the session that has waited longest to the front")
        case .search, .agentsTab, .lastNotice, .notch: nil
        }
    }

    /// What pressing the shortcut does to the notch, given how it is now. The agent and the notice to go to are looked up by the caller.
    func step(expanded: Bool, tab: NotchTab) -> ShortcutStep {
        switch self {
        case .search: expanded && tab == .search ? .collapse : .open(.search, focusSearch: true)
        case .agentsTab: expanded && tab == .agents ? .collapse : .open(.agents, focusSearch: false)
        case .notch: expanded ? .collapse : .open(nil, focusSearch: false)
        case .waitingAgent: .goToWaitingAgent
        case .lastNotice: .goToLastNotice
        }
    }

    // MARK: Saving

    private var codeKey: String { "\(rawValue)HotKeyCode" }
    private var modifiersKey: String { "\(rawValue)HotKeyModifiers" }
    private var nameKey: String { "\(rawValue)HotKeyName" }

    /// The combination saved for the action; nil when none is. Search's default is not read here (see `AppSettings.loadSearchHotKey`).
    nonisolated func loadCombo(from defaults: UserDefaults = .standard) -> HotKeyCombo? {
        guard let name = defaults.string(forKey: nameKey) else { return nil }
        return HotKeyCombo(keyCode: UInt32(defaults.integer(forKey: codeKey)),
                           modifiers: UInt32(defaults.integer(forKey: modifiersKey)), key: name)
    }

    /// Saves the combination, or forgets it for nil.
    nonisolated func saveCombo(_ combo: HotKeyCombo?, to defaults: UserDefaults = .standard) {
        guard let combo else {
            for key in [codeKey, modifiersKey, nameKey] { defaults.removeObject(forKey: key) }
            return
        }
        defaults.set(Int(combo.keyCode), forKey: codeKey)
        defaults.set(Int(combo.modifiers), forKey: modifiersKey)
        defaults.set(combo.key, forKey: nameKey)
    }

    /// The combinations saved for the actions after Search.
    nonisolated static func loadOthers(from defaults: UserDefaults = .standard) -> [ShortcutAction: HotKeyCombo] {
        var combos: [ShortcutAction: HotKeyCombo] = [:]
        for action in allCases where action != .search { combos[action] = action.loadCombo(from: defaults) }
        return combos
    }

    /// Every action that answers to a combination now: Search's only while its switch is on.
    nonisolated static func active(searchEnabled: Bool, search: HotKeyCombo, others: [ShortcutAction: HotKeyCombo]) -> [ShortcutAction: HotKeyCombo] {
        var combos = others
        if searchEnabled { combos[.search] = search }
        return combos
    }

    /// Whether recording `combo` for `action` can be saved: not when another action answers to the same keys.
    nonisolated static func assignment(of combo: HotKeyCombo, to action: ShortcutAction, active: [ShortcutAction: HotKeyCombo]) -> ShortcutAssignment {
        let owner = allCases.first { $0 != action && active[$0].map { $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers } == true }
        return owner.map(ShortcutAssignment.takenBy) ?? .saved
    }
}

enum ShortcutAssignment: Equatable {
    case saved
    case takenBy(ShortcutAction)
}

/// What the notch does when a shortcut is pressed.
enum ShortcutStep: Equatable {
    case collapse
    /// Opens the notch on the tab (nil: the one it is on), pinned, with the keyboard.
    case open(NotchTab?, focusSearch: Bool)
    case goToWaitingAgent
    case goToLastNotice
}

extension NoticeLog {
    /// The newest notice that can take you back to where it came from.
    var latestWithAction: Entry? { entries.first { $0.action != nil } }
}
