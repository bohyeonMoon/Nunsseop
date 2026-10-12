import Foundation
import Testing

/// The tests that sweep all of Unicode run in a pass of their own, picked out by `exhaustive` at the start of the test's name, because `swift test`
/// has no option for a tag. A test with the tag and without the word, or the word and without the tag, would run in the wrong pass or in both.
struct ExhaustiveTagTests {
    @Test func theTagAndTheNameSelectTheSameTests() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var tagged: Set<String> = [], named: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") where line.contains("@Test") {
                let function = line.components(separatedBy: "func ").dropFirst().first?.prefix { $0 != "(" }.description ?? ""
                if line.contains("tags(.exhaustive)") { tagged.insert(file.lastPathComponent + " " + function) }
                if function.hasPrefix("exhaustive") { named.insert(file.lastPathComponent + " " + function) }
            }
        }
        #expect(tagged == named, "tagged only: \(tagged.subtracting(named)), named only: \(named.subtracting(tagged))")
        #expect(tagged.count >= 11, "\(tagged.count)")
    }
}
