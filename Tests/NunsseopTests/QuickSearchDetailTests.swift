import AppKit
import Testing
@testable import Nunsseop

@MainActor
struct QuickSearchDetailTests {
    private func model() -> (QuickSearchModel, NSPasteboard) {
        let board = NSPasteboard(name: NSPasteboard.Name("nunsseop-test-\(UUID().uuidString)"))
        return (QuickSearchModel(clipboard: ClipboardHistory(pasteboard: board), emoji: EmojiModel(), tools: ToolsModel()), board)
    }

    @Test func aSumIsTheAnswerAndKeepsWhatWasTypedForTheDetailPane() {
        let (search, board) = model()
        defer { board.releaseGlobally() }
        search.query = "12*(3+4)*17"
        let first = search.results.first
        #expect(first?.isAnswer == true)
        #expect(first?.title == Calculator.format(1428))
        #expect(first?.detail == "12*(3+4)*17")
        #expect(search.results.dropFirst().allSatisfy { !$0.isAnswer })
    }

    @Test func anAppResultCarriesItsPathAndTheWebResultNone() {
        let (search, board) = model()
        defer { board.releaseGlobally() }
        search.loadApps()
        guard let app = search.apps.first else { return }
        search.query = app.name
        #expect(search.results.first { $0.id == "app-\(app.url.path)" }?.detail == app.url.path)
        #expect(search.results.first { $0.id == "web" }?.detail == nil)
    }
}
