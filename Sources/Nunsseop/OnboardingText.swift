import Foundation

/// Everything the tour says. Each sentence is a key of the Localizable.strings files, and OnboardingTests checks that all
/// of them are translated, so a new one is written here and nowhere else.
enum OnboardingText {
    // The frame
    static var title: String { String(localized: "Welcome tour") }
    static var skip: String { String(localized: "Skip") }
    static var back: String { String(localized: "Back") }
    static var next: String { String(localized: "Next") }
    static var done: String { String(localized: "Done") }
    static func stepLabel(_ step: Int, of total: Int) -> String {
        String(format: String(localized: "Step %lld of %lld"), step, total)
    }
    static var reopen: String {
        String(localized: "Reopen this tour from Settings › General › Show the welcome tour again")
    }
    static var showAgain: String { String(localized: "Show the welcome tour again") }

    // Opening and closing
    static var openingTitle: String { String(localized: "This is Nunsseop") }
    /// Without a notch the eyebrow is a pill that fades after `hideAfter` seconds, when it does fade.
    static func opening(hasNotch: Bool, hideAfter seconds: Int?) -> (text: String, note: String?) {
        if hasNotch {
            return (String(localized: "Hover over the notch, or swipe down with two fingers, to open it. Move the pointer away to close it."),
                    String(localized: "At first there is nothing to see."))
        }
        return (String(localized: "Move the pointer to the top center to open it, away to close it."),
                seconds.map { String(format: String(localized: "The pill fades after %lld seconds and returns at the top edge."), $0) })
    }
    static var closedNotchCaption: String { String(localized: "Closed · hover over it") }
    static var closedPillCaption: String { String(localized: "Pill · go to the top edge") }
    static var openCaption: String { String(localized: "Open · leave to close") }

    // Tabs
    static var tabsTitle: String { String(localized: "Tabs are icons") }
    static var tabsText: String {
        String(localized: "Tabs show only icons; hover over one to see its name. Here they have labels.")
    }
    static var tabsHint: String {
        String(localized: "Right-click the notch › Settings… to hide or reorder tabs.")
    }

    // Files and search
    /// The page has one thing less to say when the shortcut for Search is off.
    static func files(showsSearch: Bool) -> (title: String, text: String) {
        showsSearch ? (String(localized: "Drop and search"), String(localized: "The two things you will use most."))
            : (String(localized: "Drop files"), String(localized: "The quickest way to keep files at hand."))
    }
    static var dropTitle: String { String(localized: "Drag files onto the notch") }
    static var dropText: String {
        String(localized: "They collect on the Shelf. Send them with AirDrop or Share; screenshots land there too.")
    }
    static var searchTitle: String { String(localized: "to open Search") }
    static var searchText: String { String(localized: "Find apps, files, commands and emoji, and do math.") }

    // Agents
    static var agentsTitle: String { String(localized: "Connect your agents") }
    static var agentsText: String {
        String(localized: "Tools found on this Mac are listed. Connect one to see its sessions and reply in the Agents tab.")
    }
    static var agentsNote: String { String(localized: "Or connect later in Settings › Alerts.") }
    static var connect: String { String(localized: "Connect") }
    static var retry: String { String(localized: "Retry") }
    static func connectLabel(_ tool: String) -> String { String(format: String(localized: "Connect %@"), tool) }
    static var notConnected: String { String(localized: "Not connected") }
    static var connected: String { String(localized: "Connected") }
    static var connectedBackedUp: String { String(localized: "Connected · old settings backed up") }
    static var connectedTrust: String { String(localized: "Connected · asks once to trust the hooks") }
    static var trustHooks: String { String(localized: "Asks once to trust the hooks") }
    static var notificationsOff: String { String(localized: "Turned off in Settings › Alerts") }
    static func couldntChange(_ path: String) -> String { String(format: String(localized: "Couldn't change %@"), path) }

    // Ready
    static var readyTitle: String { String(localized: "You're all set") }
    static func ready(hasNotch: Bool) -> String {
        hasNotch ? String(localized: "Now hover over the notch.") : String(localized: "Now move the pointer to the top of the screen.")
    }
    static var permissionsTitle: String { String(localized: "Most permissions are asked on first use") }
    static var permissionsText: String { String(localized: "Calendar, screen recording and camera: when used") }
    static var login: String { String(localized: "Open at login") }
    static var loginOn: String { String(localized: "On · change in Settings › General") }
    static var loginOff: String { String(localized: "Off · change in Settings › General") }
    static var loginNeedsApproval: String { String(localized: "Allow Nunsseop in System Settings › General › Login Items.") }
    static func loginMoveApp(_ path: String) -> String {
        String(format: String(localized: "Move the app to /Applications before turning this on. Current location: %@"), path)
    }
}
