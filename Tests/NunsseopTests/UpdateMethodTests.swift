import Foundation
import Testing
@testable import Nunsseop

struct UpdateMethodTests {
    private let home = URL(fileURLWithPath: "/Users/me")
    private let team = UpdateMethod.releaseTeam

    private func decide(_ path: String, team: String? = UpdateMethod.releaseTeam, caskroom: [URL] = [], debug: Bool = false,
                        anywhere: Bool = false) -> UpdateMethod {
        UpdateMethod.decide(bundle: URL(fileURLWithPath: path), home: home, caskroomApps: caskroom, team: team, debug: debug, anywhere: anywhere)
    }

    @Test func aReleaseInAnApplicationsFolderUpdatesItself() {
        #expect(decide("/Applications/Nunsseop.app") == .sparkle)
        #expect(decide("/Applications/Utilities/Nunsseop.app") == .sparkle)
        #expect(decide("/Users/me/Applications/Nunsseop.app") == .sparkle)
    }

    @Test func aCopyAnywhereElseOrSignedByAnyoneElseGetsTheDMG() {
        for path in ["/Users/me/Desktop/DEV/Nunsseop/build/Nunsseop.app", "/Users/me/Downloads/Nunsseop.app", "/Volumes/Nunsseop/Nunsseop.app",
                     "/private/var/folders/xy/T/AppTranslocation/1234/d/Nunsseop.app", "/ApplicationsX/Nunsseop.app", "/Users/other/Applications/Nunsseop.app"] {
            #expect(decide(path) == .manual, Comment(rawValue: path))
        }
        // Ad hoc and self-signed copies, and forks signed by another team.
        #expect(decide("/Applications/Nunsseop.app", team: nil) == .manual)
        #expect(decide("/Applications/Nunsseop.app", team: "ABCDE12345") == .manual)
        // A debug build, even signed with the Developer ID and moved to Applications.
        #expect(decide("/Applications/Nunsseop.app", debug: true) == .manual)
    }

    @Test func homebrewsCopyIsTheOneItsCaskroomLinksTo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-cask-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Applications/Nunsseop.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("Caskroom/nunsseop/0.38.0/Nunsseop.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let decideHere = { (path: URL, team: String?) in
            UpdateMethod.decide(bundle: path, home: folder, caskroomApps: [link], team: team, debug: false, anywhere: true)
        }
        #expect(decideHere(app, team) == .homebrew)
        #expect(decideHere(app, nil) == .homebrew)
        // A Caskroom left behind after moving to the DMG, pointing elsewhere or nowhere, doesn't make a copy Homebrew's.
        let other = folder.appendingPathComponent("Other/Nunsseop.app")
        #expect(decideHere(other, team) == .sparkle)
        try FileManager.default.removeItem(at: app)
        #expect(decideHere(other, team) == .sparkle)
    }

    @Test func theCaskroomIsReadForEveryVersionUnderEitherPrefix() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-prefix-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: prefix) }
        for version in ["0.37.0", "0.38.0"] {
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/nunsseop/\(version)"), withIntermediateDirectories: true)
        }
        let found = UpdateMethod.caskroomApps(prefixes: [prefix.path, "/nonexistent"]).map(\.lastPathComponent)
        #expect(found == ["Nunsseop.app", "Nunsseop.app"])
    }

    @Test func theTestOnlyKeyLetsAnyCopyUpdateButNeverHomebrews() {
        #expect(decide("/private/var/folders/xy/T/e2e/old/Nunsseop.app", team: nil, anywhere: true) == .sparkle)
        #expect(decide("/Applications/Nunsseop.app", team: nil, caskroom: [URL(fileURLWithPath: "/Applications/Nunsseop.app")], anywhere: true) == .homebrew)
    }

    @Test func theTeamIsReadFromTheSignature() {
        // The test runner is signed ad hoc, or not at all.
        #expect(UpdateMethod.teamIdentifier(ofBundleAt: Bundle.main.bundleURL) == nil)
        #expect(UpdateMethod.teamIdentifier(ofBundleAt: URL(fileURLWithPath: "/nonexistent.app")) == nil)
        // Apple's own apps carry no Team ID either; what matters is that a signed bundle is read without failing.
        #expect(UpdateMethod.teamIdentifier(ofBundleAt: URL(fileURLWithPath: "/System/Applications/Calculator.app")) == nil)
    }

    @Test func sparkleFailingOffersTheDMGButTurningDownTheAuthorizationDoesNot() {
        #expect(!SparkleUpdater.offersDownload(after: nil))
        #expect(SparkleUpdater.offersDownload(after: 1001))   // no update in the feed although GitHub has one
        #expect(SparkleUpdater.offersDownload(after: 2001))
        #expect(!SparkleUpdater.offersDownload(after: 4007))  // the user canceled the authorization prompt
    }
}

struct UpdateStringsTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }

    @Test func theSparkleSentencesAreTranslatedIntoEveryLanguage() throws {
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in ["Install Update", "Shows what's new, then installs the update and restarts Nunsseop."] {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
            }
        }
    }
}

/// scripts/appcast.py, which writes the feed a release publishes.
struct AppcastTests {
    private let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/appcast.py")
    private let signature = Data(repeating: 7, count: 64).base64EncodedString()

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = try #require(PythonTool.url)
        process.arguments = ["-I", script.path] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }

    private func render(version: String = "0.38.0", build: String = "72", url: String = "https://github.com/namekun/Nunsseop/releases/download/v0.38.0/Nunsseop-0.38.0.dmg",
                        length: String = "5052254", signature: String? = nil, notes: String = "New **things**", minOS: String = "14.0",
                        in folder: URL) throws -> (status: Int32, feed: String, error: String) {
        let notesFile = folder.appendingPathComponent("notes.md"), out = folder.appendingPathComponent("appcast.xml")
        try notes.write(to: notesFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: out)
        let result = try run(["render", "--version", version, "--build", build, "--url", url, "--length", length, "--signature", signature ?? self.signature,
                              "--notes", notesFile.path, "--min-os", minOS, "--date", "Wed, 21 Oct 2026 09:00:00 +0000", "--out", out.path])
        return (result.status, (try? String(contentsOf: out, encoding: .utf8)) ?? "", result.error)
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-appcast-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func anItemSaysWhatSparkleComparesAndWhereTheSignedDMGIs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try render(in: folder)
        #expect(result.status == 0, Comment(rawValue: result.error))
        for part in ["<sparkle:version>72</sparkle:version>", "<sparkle:shortVersionString>0.38.0</sparkle:shortVersionString>",
                     "<sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>", "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>",
                     #"url="https://github.com/namekun/Nunsseop/releases/download/v0.38.0/Nunsseop-0.38.0.dmg" length="5052254""#,
                     "sparkle:edSignature=\"\(signature)\"", "<![CDATA[New **things**]]>", "<pubDate>Wed, 21 Oct 2026 09:00:00 +0000</pubDate>"] {
            #expect(result.feed.contains(part), Comment(rawValue: part))
        }
        #expect(try run(["max-build", folder.appendingPathComponent("appcast.xml").path]).output == "72\n")
        let check = ["check", folder.appendingPathComponent("appcast.xml").path, "--version", "0.38.0", "--build", "72",
                     "--url", "https://github.com/namekun/Nunsseop/releases/download/v0.38.0/Nunsseop-0.38.0.dmg", "--length", "5052254", "--signature", signature]
        #expect(try run(check).status == 0)
        // Each field the release promised is compared.
        for (index, wrong) in [(3, "0.38.1"), (5, "73"), (7, "https://example.com/x.dmg"), (9, "5052255"), (11, Data(repeating: 8, count: 64).base64EncodedString())] {
            var changed = check
            changed[index] = wrong
            #expect(try run(changed).status == 1, Comment(rawValue: wrong))
        }
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func notesThatCloseCDATAStayNotesAndTheFeedStillParses() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try render(notes: "a ]]> b <script>", in: folder)
        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(try run(["max-build", folder.appendingPathComponent("appcast.xml").path]).output == "72\n")
        #expect(result.feed.contains("a ]]]]><![CDATA[> b <script>"))
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func whatSparkleCantTrustIsRefused() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for build in ["0", "072", "7a", "-1"] { #expect(try render(build: build, in: folder).status == 1, Comment(rawValue: build)) }
        for version in ["0.38", "v0.38.0", "0.38.0-beta.1"] { #expect(try render(version: version, in: folder).status == 1, Comment(rawValue: version)) }
        for url in ["http://example.com/x.dmg", "file:///x.dmg"] { #expect(try render(url: url, in: folder).status == 1, Comment(rawValue: url)) }
        #expect(try render(url: "http://127.0.0.1:8080/files/x.dmg", in: folder).status == 0)
        for length in ["0", "-5", "big"] { #expect(try render(length: length, in: folder).status == 1, Comment(rawValue: length)) }
        for bad in [Data(repeating: 7, count: 63).base64EncodedString(), "not base64!"] {
            #expect(try render(signature: bad, in: folder).status == 1, Comment(rawValue: bad))
        }
        #expect(try render(minOS: "fourteen", in: folder).status == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("appcast.xml").path))
    }

    @Test(.enabled(if: PythonTool.available, PythonTool.reason))
    func theHighestBuildOfAFeedIsZeroWithoutItemsAndAnErrorWhenBroken() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = folder.appendingPathComponent("feed.xml")
        try #"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>9</sparkle:version></item><item><sparkle:version>12</sparkle:version></item></channel></rss>"#
            .write(to: feed, atomically: true, encoding: .utf8)
        #expect(try run(["max-build", feed.path]).output == "12\n")
        try "<rss><channel></channel></rss>".write(to: feed, atomically: true, encoding: .utf8)
        #expect(try run(["max-build", feed.path]).output == "0\n")
        try "<rss><channel>".write(to: feed, atomically: true, encoding: .utf8)
        #expect(try run(["max-build", feed.path]).status == 1)
    }
}
