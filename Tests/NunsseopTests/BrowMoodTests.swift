import Foundation
import Testing
@testable import Nunsseop

struct BrowMoodTests {
    private func entry(_ id: String, _ state: AgentBoard.State, finished: Bool = false) -> AgentBoard.Entry {
        AgentBoard.Entry(source: "hooks:claude", id: id, agent: AgentBoard.Agent(state: state, finished: finished, tool: "claude"))
    }

    @Test func oneAgentAskingOutweighsAnyAtWork() {
        #expect(BrowMood.steady([]) == .rest)
        #expect(BrowMood.steady([entry("a", .working), entry("b", .idle)]) == .focused)
        #expect(BrowMood.steady([entry("a", .working), entry("b", .working), entry("c", .waiting)]) == .waiting)
    }

    @Test func aFinishedTurnNobodyLookedAtIsNotAsking() {
        #expect(BrowMood.steady([entry("a", .waiting, finished: true)]) == .rest)
        #expect(BrowMood.steady([entry("a", .waiting, finished: true), entry("b", .working)]) == .focused)
    }

    @Test func aTurnIsCheeredOnceWhenItEnds() {
        var watch = FinishWatch()
        // Already finished when first seen: nothing to cheer, it ended before.
        #expect(watch.step([entry("a", .waiting, finished: true), entry("b", .working)]).isEmpty)
        #expect(watch.step([entry("a", .waiting, finished: true), entry("b", .working)]).isEmpty)
        #expect(watch.step([entry("a", .waiting, finished: true), entry("b", .waiting, finished: true)]).map(\.id) == ["b"])
        #expect(watch.step([entry("a", .waiting, finished: true), entry("b", .waiting, finished: true)]).isEmpty)
    }

    @Test func askingForInputIsNotAFinish() {
        var watch = FinishWatch()
        _ = watch.step([entry("a", .working)])
        #expect(watch.step([entry("a", .waiting)]).isEmpty)
        // Working again, then done.
        _ = watch.step([entry("a", .working)])
        #expect(watch.step([entry("a", .waiting, finished: true)]).map(\.id) == ["a"])
    }

    @Test func aNoticeNamesAMoodInPlaceOfASymbol() {
        for mood in BrowMood.allCases {
            #expect(BrowMood(symbol: mood.symbol) == mood)
        }
        #expect(BrowMood(symbol: "sparkles") == nil)
        #expect(BrowMood(symbol: "brow.grumpy") == nil)
    }

    @Test func onlyTheMomentsPass() {
        #expect(BrowMood.allCases.filter { $0.lasts != nil } == [.happy, .tired, .relieved])
    }

    /// The pill without a camera is 18 high with the 24 × 10 eyebrow in its middle, and clips what passes its edges: every face
    /// keeps clear of them, with room left for the cheer's hop.
    @Test func everyFaceStaysInsideThePill() {
        let frame = CGRect(x: 0, y: 4, width: 24, height: 10)
        for mood in BrowMood.allCases {
            let box = EyebrowArch(lift: 0, pose: mood.pose).path(in: frame).boundingRect
            #expect(box.minY - EyebrowMark.hopHeight >= 0 && box.maxY <= 18, Comment(rawValue: "\(mood): \(box)"))
        }
    }

    @Test func theFacesDifferEnoughToTell() {
        // The head (x 10) and the tail (x 90) together tell the faces apart; no two are within 3 grid units at both.
        let faces = BrowMood.allCases.map { ($0, $0.pose.rise(at: 10), $0.pose.rise(at: 90)) }
        for (i, a) in faces.enumerated() {
            for b in faces[(i + 1)...] {
                #expect(abs(a.1 - b.1) >= 3 || abs(a.2 - b.2) >= 3, Comment(rawValue: "\(a.0) / \(b.0)"))
            }
        }
    }

    @Test func theCheerIsTranslatedIntoEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let keys = ["Cheer when an agent finishes its turn",
                    "The eyebrow hops and the notch says which agent is done, unless its terminal is already in front. Its face also follows the agents: raised while one waits for you, low and level while they work.",
                    "%@ is done"]
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                #expect(text.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count, Comment(rawValue: "\(language): \(key)"))
            }
        }
    }
}
