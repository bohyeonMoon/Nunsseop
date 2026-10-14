import AppKit
import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct EmojiCategoryTests {
    private func model(_ label: String) -> (EmojiModel, ScratchDefaults) {
        let defaults = ScratchDefaults("emoji-\(label)")
        return (EmojiModel(defaults: defaults.defaults, pasteboard: NSPasteboard.withUniqueName()), defaults)
    }

    private func emoji(_ character: String) -> EmojiModel.Emoji {
        EmojiModel.all.first { $0.character == character }!
    }

    @Test func theListStartsWithRecentThenTheBlocksInTheOrderOfTheMock() {
        #expect(EmojiCategory.allCases == [.recent, .emoticons, .pictographs, .transport, .supplemental, .extended, .symbols, .dingbats])
        #expect(Set(EmojiCategory.allCases.map(\.title)).count == EmojiCategory.allCases.count)
    }

    @Test func everyEmojiIsInTheBlockItsCodePointBelongsTo() throws {
        for item in EmojiModel.all {
            let scalar = try #require(item.character.unicodeScalars.first)
            #expect(item.category.range?.contains(scalar.value) == true, "\(item.name) is in \(item.category)")
        }
    }

    @Test func theBlocksTogetherHoldEveryEmojiOnceAndNoneIsEmpty() {
        let (emojis, defaults) = model("blocks")
        defer { defaults.remove() }
        let blocks = EmojiCategory.allCases.filter { $0 != .recent }
        let shown = blocks.map { emojis.shown(in: $0, query: "") }
        for (block, items) in zip(blocks, shown) { #expect(!items.isEmpty, "\(block) has emoji") }
        #expect(shown.flatMap { $0 }.count == EmojiModel.all.count)
        #expect(Set(shown.flatMap { $0 }.map(\.character)).count == EmojiModel.all.count)
    }

    @Test func recentIsWhatWasCopiedNewestFirstAndEmptyBeforeThat() {
        let (emojis, defaults) = model("recent")
        defer { defaults.remove() }
        #expect(emojis.shown(in: .recent, query: "").isEmpty)
        for glyph in ["😀", "🔥", "✅"] { emojis.copy(emoji(glyph)) }
        emojis.copy(emoji("😀"))
        #expect(emojis.shown(in: .recent, query: "").map(\.character) == ["😀", "✅", "🔥"])
    }

    @Test func aSearchLooksThroughEveryCategoryWhicheverIsChosen() {
        let (emojis, defaults) = model("search")
        defer { defaults.remove() }
        let found = emojis.shown(in: .dingbats, query: "grinning face")
        #expect(found.contains { $0.category == .emoticons })
        #expect(found.allSatisfy { $0.name.contains("grinning face") })
        #expect(emojis.shown(in: .recent, query: "grinning face") == found)
    }

    @Test func aQueryOfOnlySpacesIsNotASearch() {
        let (emojis, defaults) = model("blank")
        defer { defaults.remove() }
        #expect(emojis.shown(in: .transport, query: "   ") == emojis.shown(in: .transport, query: ""))
        #expect(emojis.shown(in: .transport, query: "").allSatisfy { $0.category == .transport })
    }

    @Test func copyingPutsTheEmojiOnItsPasteboardAndConfirmsIt() async throws {
        let defaults = ScratchDefaults("emoji-copy")
        defer { defaults.remove() }
        let pasteboard = NSPasteboard.withUniqueName()
        let emojis = EmojiModel(defaults: defaults.defaults, pasteboard: pasteboard)
        emojis.copy(emoji("👍"))
        #expect(pasteboard.string(forType: .string) == "👍")
        #expect(emojis.copied == "👍")
        #expect(EmojiModel(defaults: defaults.defaults, pasteboard: pasteboard).recents == ["👍"])
        // The confirmation goes by itself.
        for _ in 0..<100 where emojis.copied != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(emojis.copied == nil)
    }

    @Test func theRecentListKeepsEighteen() {
        let (emojis, defaults) = model("cap")
        defer { defaults.remove() }
        for item in EmojiModel.all.prefix(25) { emojis.copy(item) }
        #expect(emojis.recents.count == 18)
        #expect(emojis.shown(in: .recent, query: "").count == 18)
    }
}
