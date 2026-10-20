import AppKit

signal(SIGPIPE, SIG_IGN)

// For check-dmg.sh: the Team ID the running copy reads from its own signature, which decides whether it updates itself.
if CommandLine.arguments.dropFirst().first == "--print-update-team" {
    print(UpdateMethod.teamIdentifier(ofBundleAt: Bundle.main.bundleURL) ?? "none")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
