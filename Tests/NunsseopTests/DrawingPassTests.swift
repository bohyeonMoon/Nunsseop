import Foundation
import Testing

/// The suites that draw views run in a pass of their own (`DRAWING` in scripts/test.sh), picked out by the name of the suite, because they hold the
/// main actor for seconds on end and everything that waits for it waits behind them. A suite that draws and is not named there would hold it
/// in the other pass, and one that is named and does not draw would be left out of it for nothing.
struct DrawingPassTests {
    @Test func theSuitesTheDrawingPassNamesAreTheOnesThatDrawViews() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let script = try String(contentsOf: folder.appendingPathComponent("../../scripts/test.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("DRAWING=") })
        let named = Set(try #require(line.split(separator: "(").dropFirst().first?.split(separator: ")").first).split(separator: "|").map(String.init))

        var draws: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" && file.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent {
            var suite: String?
            var tests = false, drawing = false
            func close() {
                if let suite, tests, drawing { draws.insert(suite) }
            }
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                if let declared = ["final class ", "struct ", "enum "].first(where: line.hasPrefix) {
                    close()
                    suite = String(line.dropFirst(declared.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                    tests = false
                    drawing = false
                }
                if line.contains("@Test") { tests = true }
                if line.contains("NSHostingView(") || line.contains("EarRender.") { drawing = true }
            }
            close()
        }
        #expect(draws == named, "draw only: \(draws.subtracting(named)), named only: \(named.subtracting(draws))")
        #expect(named.count >= 8, "\(named.count)")
    }
}
