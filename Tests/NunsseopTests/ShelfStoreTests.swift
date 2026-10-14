import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct ShelfStoreTests {
    private func store() -> ShelfStore {
        ShelfStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString).json"))
    }

    @Test func newItemsComeFirst() {
        let shelf = store()
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png"), c = URL(fileURLWithPath: "/tmp/c.png")
        shelf.add([a])
        shelf.add([b, c])
        #expect(shelf.items.map(\.url) == [b, c, a])
    }

    @Test func aFileAlreadyOnTheShelfIsNotAddedTwice() {
        let shelf = store()
        let a = URL(fileURLWithPath: "/tmp/a.png")
        shelf.add([a])
        shelf.add([a])
        #expect(shelf.items.count == 1)
    }
}
