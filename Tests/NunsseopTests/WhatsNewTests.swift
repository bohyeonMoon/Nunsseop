import AppKit
import Foundation
import Testing
@testable import Nunsseop

private func withDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "NunsseopTests.WhatsNew.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try body(defaults)
}

@MainActor
private func makeTour(_ defaults: UserDefaults) -> OnboardingTour {
    OnboardingTour(defaults: defaults, presentTools: { [] }, isConnected: { _ in false }, connectTool: { _ in }, hasBackup: { _ in false })
}

@MainActor
struct WhatsNewTests {
    private let version = "0.35.0"

    @Test func theNotesShowOnceAfterAnUpdateToAVersionThatHasThem() {
        withDefaults { defaults in
            defaults.set(true, forKey: OnboardingTour.doneKey)
            defaults.set("0.33.5", forKey: WhatsNew.seenKey)
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: false, version: version)
            #expect(tour.isPending && tour.news?.version == version)
            tour.start()
            #expect(tour.steps == [.whatsNew] && tour.isLast)
            tour.next()
            #expect(!tour.isActive && tour.news == nil)
            #expect(defaults.string(forKey: WhatsNew.seenKey) == version)
            // The next launch of the same version shows nothing.
            let again = makeTour(defaults)
            again.prepare(freshInstall: false, version: version)
            #expect(!again.isPending && again.news == nil)
        }
    }

    @Test func anUpdateFromBeforeThisExistedShowsThem() {
        // Earlier versions kept no record, so none counts as an older version.
        withDefaults { defaults in
            defaults.set(true, forKey: OnboardingTour.doneKey)
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: false, version: version)
            #expect(tour.news?.version == version)
        }
    }

    @Test func escapeCountsAsSeen() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: false, version: version)
            tour.start()
            tour.perform(.skip)
            #expect(defaults.string(forKey: WhatsNew.seenKey) == version && tour.news == nil)
            // Finishing the notes doesn't count as having done the tour.
            #expect(!defaults.bool(forKey: OnboardingTour.doneKey))
        }
    }

    @Test func aFreshInstallGetsTheTourAndNotTheNotesNowOrNextLaunch() {
        withDefaults { defaults in
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: true, version: version)
            #expect(tour.isPending && tour.news == nil)
            tour.start()
            #expect(tour.steps == OnboardingTour.steps(hasTools: false))
            tour.skip()
            let next = makeTour(defaults)
            next.prepare(freshInstall: false, version: version)
            #expect(!next.isPending && next.news == nil)
        }
    }

    @Test func replayingTheTourFromSettingsShowsTheTourWhileNotesWait() {
        withDefaults { defaults in
            defaults.set(true, forKey: OnboardingTour.doneKey)
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: false, version: version)
            tour.replay()
            #expect(tour.steps == OnboardingTour.steps(hasTools: false) && tour.news == nil)
            tour.skip()
            // The notes weren't seen, so the next launch still shows them.
            #expect(defaults.string(forKey: WhatsNew.seenKey) == nil)
            let next = makeTour(defaults)
            next.prepare(freshInstall: false, version: version)
            #expect(next.news?.version == version)
        }
    }

    @Test func aVersionWithoutNotesShowsNothing() {
        withDefaults { defaults in
            defaults.set("0.33.5", forKey: WhatsNew.seenKey)
            let tour = makeTour(defaults)
            tour.prepare(freshInstall: false, version: "9.9.9")
            #expect(!tour.isPending && tour.news == nil)
            #expect(WhatsNew.notes(for: "9.9.9") == nil)
        }
    }

    @Test func theNotesForThisReleaseHaveAtMostWhatFitsAndRealSymbols() throws {
        let notes = try #require(WhatsNew.notes(for: version))
        // Two rows of 36 points and the gap between them fill the visual column.
        #expect((1...2).contains(notes.items.count))
        for item in notes.items {
            #expect(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) != nil, Comment(rawValue: item.symbol))
        }
        #expect(notes.text.contains(version))
    }

    @Test func theNotesAreTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["What's new in %@", "Now with feelings", "Nunsseop %@ wears its mood on its brow. Also new: a Monday recap, more shortcuts and six more agents.",
                    "A brow with moods", "Raised when an agent waits, a hop when it's done", "What your agents are doing",
                    "Their last step, and the diff a click away", "Got it"]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                let wanted = key.components(separatedBy: "%@").count - 1
                let found = text.components(separatedBy: "%@").count - 1 + (1...2).filter { text.contains("%\($0)$@") }.count
                #expect(found == wanted, Comment(rawValue: "\(language): \(key)"))
            }
            // A row's line under its title is one line of about 286 points (the visual column less the icon and padding).
            let font = NSFont.systemFont(ofSize: 11)
            for key in ["Raised when an agent waits, a hop when it's done", "Their last step, and the diff a click away"] {
                let text = (table[key] as? String ?? "").replacingOccurrences(of: "%1$@", with: "80 %").replacingOccurrences(of: "%2$@", with: "95 %")
                #expect((text as NSString).size(withAttributes: [.font: font]).width <= 280, Comment(rawValue: "\(language): \(text)"))
            }
        }
    }
}
