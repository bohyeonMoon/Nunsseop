import AppKit
import SwiftUI

/// The apps pinned to the Dock, followed by its recent apps, ready to launch from the notch.
@MainActor
final class AppLauncher: ObservableObject {
    struct App: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
    }

    @Published private(set) var apps: [App] = []

    func reload() {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let entries = (dock?.array(forKey: "persistent-apps") ?? []) + (dock?.array(forKey: "recent-apps") ?? [])
        var seen = Set<URL>()
        apps = entries.compactMap { entry -> App? in
            guard let tile = (entry as? [String: Any])?["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return nil }
            let url = string.hasPrefix("file://") ? URL(string: string) : URL(fileURLWithPath: string)
            guard let url, url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path),
                  seen.insert(url).inserted else { return nil }
            return App(url: url, name: InstalledApps.name(at: url))
        }
    }

    func open(_ app: App) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct AppsTab: View {
    @ObservedObject var launcher: AppLauncher
    @State private var selection = DetailSelection<URL>()

    var body: some View {
        Group {
            if launcher.apps.isEmpty {
                Text("Apps in your Dock show up here")
                    .font(.system(size: 12)).foregroundStyle(PanelInk.hint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelSplit {
                    PanelList(items: launcher.apps, selection: $selection) { app, selected in
                        AppRow(app: app, selected: selected) { launcher.open(app) }
                    }
                } right: {
                    detail
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { launcher.reload() }
    }

    @ViewBuilder private var detail: some View {
        let shown = selection.current(in: launcher.apps.map(\.id)).flatMap { id in launcher.apps.first { $0.id == id } }
        if let shown {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(nsImage: InstalledApps.icon(at: shown.url)).resizable().frame(width: 60, height: 60).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: shown.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("Application").font(.system(size: 11)).foregroundStyle(PanelInk.secondary)
                        Text(verbatim: shown.url.path).font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 8) {
                    PanelAction(title: "Open", symbol: "arrow.up.forward.app", style: .primary) { launcher.open(shown) }
                    Text(launcher.apps.count == 1 ? String(localized: "1 app from your Dock") : String(localized: "\(launcher.apps.count) apps from your Dock"))
                        .font(.system(size: 11)).foregroundStyle(PanelInk.hint).lineLimit(1)
                }
            }
            .padding(.top, 14)
        }
    }
}

private struct AppRow: View {
    let app: AppLauncher.App
    let selected: Bool
    let action: () -> Void

    var body: some View {
        LedgerRow(selected: selected) {
            HStack(spacing: 8) {
                Image(nsImage: InstalledApps.icon(at: app.url)).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                Text(verbatim: app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help(app.name)
    }
}

/// Name and icon of installed apps. Finding an app by bundle ID and loading its icon is slow enough
/// to matter in a view body, so apps that were found are remembered; missing ones are looked up again.
enum InstalledApps {
    private static let urls = NSCache<NSString, NSURL>()
    private static let icons = NSCache<NSString, NSImage>()

    static func url(for bundleID: String) -> URL? {
        // A cached location is dropped if the app has since moved or been removed.
        if let url = urls.object(forKey: bundleID as NSString) as URL?, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        urls.setObject(url as NSURL, forKey: bundleID as NSString)
        return url
    }

    static func name(at url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(at url: URL) -> NSImage {
        if let icon = icons.object(forKey: url.path as NSString) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: url.path as NSString)
        return icon
    }

    static func icon(for bundleID: String) -> NSImage? { url(for: bundleID).map(icon(at:)) }
}
