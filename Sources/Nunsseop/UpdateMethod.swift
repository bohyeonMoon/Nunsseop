import Foundation
import Security

/// How this copy of Nunsseop gets a new version.
enum UpdateMethod: Equatable {
    /// Installed by Homebrew: Settings copies the upgrade command.
    case homebrew
    /// A release installed from the DMG into an Applications folder: Sparkle installs the update.
    case sparkle
    /// Anything else, such as a build or a copy run from Downloads: Settings opens the new DMG.
    case manual

    /// The team of the Developer ID that signs releases. Builds signed otherwise, forks included, never replace themselves.
    nonisolated static let releaseTeam = "8V3FJ9FB77"

    nonisolated static let current: UpdateMethod = {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let bundle = Bundle.main.bundleURL
        return decide(bundle: bundle, home: FileManager.default.homeDirectoryForCurrentUser, caskroomApps: caskroomApps(),
                      team: teamIdentifier(ofBundleAt: bundle), debug: debug,
                      anywhere: Bundle.main.object(forInfoDictionaryKey: anywhereKey) as? Bool == true)
    }()

    /// Lets a copy outside an Applications folder and without the release team update itself. Only the copies that
    /// scripts/e2e-update.sh makes have it; check-dmg.sh makes sure a release doesn't.
    nonisolated static let anywhereKey = "NunsseopUpdaterAnywhere"

    /// Homebrew links the app it installed from its Caskroom, so a copy is Homebrew's only when such a link leads to it; a
    /// Caskroom whose link leads nowhere, or elsewhere, doesn't count. (A DMG copy dragged over Homebrew's at the same path
    /// still does, and gets the brew command.)
    nonisolated static func decide(bundle: URL, home: URL, caskroomApps: [URL], team: String?, debug: Bool, anywhere: Bool) -> UpdateMethod {
        let path = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        if caskroomApps.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }) { return .homebrew }
        if debug { return .manual }
        if anywhere { return .sparkle }
        guard team == releaseTeam else { return .manual }
        let folders = ["/Applications/", home.appendingPathComponent("Applications").standardizedFileURL.path + "/"]
        return folders.contains { path.hasPrefix($0) } ? .sparkle : .manual
    }

    /// `Caskroom/nunsseop/<version>/Nunsseop.app` under either Homebrew prefix.
    nonisolated static func caskroomApps(prefixes: [String] = ["/opt/homebrew", "/usr/local"]) -> [URL] {
        prefixes.flatMap { prefix -> [URL] in
            let cask = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/nunsseop")
            let versions = (try? FileManager.default.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil)) ?? []
            return versions.map { $0.appendingPathComponent("Nunsseop.app") }
        }
    }

    /// The Team ID the bundle is signed with; nil for ad hoc and self-signed signatures.
    nonisolated static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
