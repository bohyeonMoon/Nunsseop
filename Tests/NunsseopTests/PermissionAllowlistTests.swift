import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Nunsseop

/// What `PermissionText.escape` shows as it is has to lay out inside the row it is drawn in, whatever font CoreText falls back
/// to, and has to be what normalization leaves alone. Every scalar is asked, not a list of the ones that went wrong before.
struct PermissionAllowlistTests {
    /// A font the card draws escaped text in, with the room its row has: the rows are stacked with nothing between them.
    private struct Face {
        let name: String
        let font: NSFont
        var above: CGFloat { ceil(font.ascender) }
        var below: CGFloat { ceil(-font.descender) + ceil(font.leading) }
    }

    /// The detail and the rules, the title, and the folder.
    private let faces = [Face(name: "code", font: PermissionLayout.codeFont), Face(name: "title", font: PermissionLayout.titleFont),
                         Face(name: "folder", font: .systemFont(ofSize: 11))]

    /// Ink may pass the row's edge by a twentieth of a point, a tenth of a pixel on the sharpest display, and still not draw a pixel there.
    private let slack: CGFloat = 0.05

    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }
    private func name(_ text: String) -> String { text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ") }
    private func hex(_ values: UInt32...) -> String { values.map { String(format: "⟨U+%04X⟩", $0) }.joined() }
    private func escaped(_ text: String) -> String { PermissionText.escape(text, multiline: true) }
    private func shown(_ text: String) -> Bool { scalars(PermissionText.escape(text, multiline: false)) == scalars(text) }
    private func stable(_ text: String) -> Bool { scalars(text.precomposedStringWithCanonicalMapping) == scalars(text) }

    /// Why `text` doesn't lay out in a row of `face`, nil when it does: no width, no ink, or ink above or below the row.
    private func problem(_ text: String, in face: Face) -> String? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: face.font]))
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > 0 else { return "no width" }
        if text == " " { return nil }
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull, ink.width > 0, ink.height > 0 else { return "no ink" }
        if ink.maxY > face.above + slack { return String(format: "%@ rises %.2f above the row", face.name, ink.maxY - face.above) }
        if ink.minY < -face.below - slack { return String(format: "%@ sinks %.2f below the row", face.name, -face.below - ink.minY) }
        return nil
    }

    private func problem(_ text: String) -> String? { faces.lazy.compactMap { problem(text, in: $0) }.first }

    /// The line drawn into a bitmap two pixels to the point, to read the ink off the pixels the glyph outlines may not tell.
    private final class Raster {
        let width = 240
        var pixels = [UInt8](repeating: 0, count: 240 * 2 * 42 * 2 * 4)
        let context: CGContext

        init() {
            context = pixels.withUnsafeMutableBytes {
                CGContext(data: $0.baseAddress, width: 240 * 2, height: 42 * 2, bitsPerComponent: 8, bytesPerRow: 240 * 2 * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            }
            context.scaleBy(x: 2, y: 2)
        }

        /// How many pixels, at most, the line draws above or below its row (the middle third of the bitmap).
        func overflow(_ text: String, in face: Face) -> Int {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: face.font]))
            let used = min(width, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))) + 12)
            context.clear(CGRect(x: 0, y: 0, width: used, height: 42))
            context.textPosition = CGPoint(x: 4, y: 14 + face.below)
            CTLineDraw(line, context)
            let rowBottom = 28, rowTop = 56, stride = width * 2 * 4
            return pixels.withUnsafeBufferPointer { buffer in
                var worst = 0
                for y in 0..<84 where y < rowBottom || y >= rowTop {
                    let distance = y < rowBottom ? rowBottom - y : y - rowTop + 1
                    guard distance > worst else { continue }
                    for x in 0..<(used * 2) where buffer[y * stride + x * 4 + 3] >= 48 { worst = distance; break }
                }
                return worst
            }
        }
    }

    /// Every scalar that `escape` leaves alone when it stands by itself.
    private static let shownScalars: [Unicode.Scalar] = (UInt32(0)...0x10FFFF).compactMap { Unicode.Scalar($0) }.filter {
        let text = String($0)
        return text.unicodeScalars.elementsEqual(PermissionText.escape(text, multiline: false).unicodeScalars)
    }

    private typealias CharDirection = @convention(c) (Int32) -> Int32
    private typealias HasBinaryProperty = @convention(c) (Int32, Int32) -> Int8

    // MARK: Single scalars

    @Test func everyScalarShownAsItIsDrawsInsideItsRowInEveryFontTheCardUses() throws {
        let library = try #require(dlopen("/usr/lib/libicucore.dylib", RTLD_NOW))
        let direction = unsafeBitCast(try #require(dlsym(library, "u_charDirection")), to: CharDirection.self)
        let hasProperty = unsafeBitCast(try #require(dlsym(library, "u_hasBinaryProperty")), to: HasBinaryProperty.self)
        let extendedPictographic: Int32 = 64
        #expect(hasProperty(0x1F600, extendedPictographic) != 0 && hasProperty(0x61, extendedPictographic) == 0)
        // Left to right, weak or neutral only: R, AN, AL, the embeddings and overrides, isolates, block and segment separators, boundary neutrals.
        let refused: Set<Int32> = [1, 5, 13, 11, 12, 14, 15, 16, 19, 20, 21, 22, 7, 8, 18]
        let raster = Raster()
        var problems: [String] = []
        for scalar in Self.shownScalars {
            let text = String(scalar)
            if let why = problem(text) { problems.append("\(name(text)) \(why)") }
            // A pixel of anti-aliasing at the row's edge is not paint in the next row: colour emoji reach the very edge.
            else if raster.overflow(text, in: faces[0]) > 1 { problems.append("\(name(text)) paints past the row") }
            if !stable(text) { problems.append("\(name(text)) is changed by normalization") }
            if refused.contains(direction(Int32(scalar.value))) { problems.append("\(name(text)) is not left to right") }
            if scalar.value > 0x7F, scalar.properties.generalCategory == .unassigned { problems.append("\(name(text)) is unassigned") }
            if scalar.value >= 0x1F000 || (0x2600...0x27BF).contains(scalar.value), hasProperty(Int32(scalar.value), extendedPictographic) == 0 {
                problems.append("\(name(text)) is not an extended pictograph")
            }
        }
        #expect(problems.isEmpty, "\(problems.count): \(problems.prefix(12))")
        let all = Set(Self.shownScalars.map(\.value))
        #expect(all.count > 40_000 && all.count < 45_000, "\(all.count)")
    }

    @Test func theScalarsShownAreTheOnesTheAllowlistNamesAndNoOthers() {
        let all = Set(Self.shownScalars.map(\.value))
        let ranges: [ClosedRange<UInt32>] = [0x20...0x7E, 0xA1...0x24F, 0x1E00...0x1EFF, 0x370...0x4FF, 0x2010...0x2027, 0x2030...0x205E, 0x20A0...0x20C0,
                                             0x2100...0x214F, 0x2190...0x21FF, 0x2500...0x257F, 0x3001...0x303F, 0x3041...0x30FF, 0x3131...0x318E,
                                             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xFF01...0xFF5E, 0xFF61...0xFF9D, 0x2600...0x27BF,
                                             0x1F000...0x1FAFF]
        #expect(all.filter { value in !ranges.contains { $0.contains(value) } }.isEmpty)
        // What the allowlist names and everything else about it: ASCII, accented letters, Greek, Cyrillic, punctuation, currency, arrows, kana, ideographs, Hangul, emoji.
        for value: UInt32 in [0x20, 0x21, 0x7E, 0xE9, 0xF1, 0x141, 0x1E9E, 0x3A9, 0x44F, 0x2014, 0x2026, 0x20AC, 0x20A9, 0x2122, 0x2192, 0x2500, 0x3002, 0x3042,
                              0x30AB, 0x4E2D, 0x6F22, 0x3400, 0xD55C, 0x3131, 0xFF01, 0xFF76, 0x1F600, 0x2764, 0x2705] {
            #expect(all.contains(value), "U+\(String(value, radix: 16, uppercase: true))")
        }
        // Not shown, whatever their block: spaces, joiners and direction marks, separators, the filler letters, the voicing marks, the tab arrow, unassigned.
        for value: UInt32 in [0xA0, 0xAD, 0x2028, 0x2029, 0x200B, 0x200D, 0x2060, 0x3000, 0x3164, 0xFFA0, 0xFF9E, 0xFF9F, 0x3099, 0x309A, 0x21E5, 0x27E8, 0x27E9, 0x0378,
                              0x1100, 0x1161, 0x11A8, 0x093E, 0x16AF0, 0x16AF4, 0x12031, 0x1DD8, 0x1DD9, 0x212A, 0x212B, 0x2126, 0x037E, 0x0387, 0x1FEF, 0x1FFD,
                              0xF900, 0xFA0E, 0x2F800, 0x2329, 0x1F1E6, 0x1F3FB, 0xE0041, 0xFE0F, 0x0300, 0x1F000 + 0x3FF] {
            #expect(!all.contains(value), "U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    @Test func aScalarThatNormalizationChangesIsWrittenOutBeforeItCanBeChanged() {
        var checked = 0
        for scalar in (UInt32(0)...0x10FFFF).compactMap({ Unicode.Scalar($0) }) where !stable(String(scalar)) {
            checked += 1
            #expect(escaped("a" + String(scalar) + "b") == "a" + hex(scalar.value) + "b", "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
        #expect(checked > 1_000)
        // The card shows what is sent: none of these turn into the letter, the semicolon or the quote beside them.
        #expect(escaped("\u{212A}") == hex(0x212A) && escaped("\u{37E}") == hex(0x37E) && escaped("\u{1FEF}") == hex(0x1FEF))
        #expect(escaped("\u{212B}\u{2126}\u{387}\u{1FFD}\u{F900}\u{2F800}") == hex(0x212B, 0x2126, 0x387, 0x1FFD, 0xF900, 0x2F800))
        // What is written out stays written out beside a mark that would have composed with the letter it stands for.
        #expect(escaped("\u{212A}\u{301}") == hex(0x212A, 0x301))
    }

    // MARK: Combining marks

    private let markBases = Array("acemnorsuvwxz")

    @Test func aCombiningMarkLeftAfterNormalizationStaysOnlyWhereItFitsInsideTheRow() {
        // Marks that are never shown whether they fit or not: the grapheme joiner draws nothing, the double marks reach over the next letter.
        let refused = Set([0x34F] + Array(0x35C...0x362))
        var shownPairs = 0
        for mark in UInt32(0x300)...0x36F {
            let texts = markBases.map { String($0) + String(Unicode.Scalar(mark)!) }
            // The marks are one list for all the letters: shown on every one of them, or on none.
            let fitsAll = texts.allSatisfy { problem($0) == nil } && !refused.contains(Int(mark)) && stable(String(Unicode.Scalar(mark)!))
            for text in texts where stable(text) {
                // Where normalization composes the pair, what is shown is the composed letter, one scalar, checked above.
                #expect(shown(text) == fitsAll, "\(name(text)) \(problem(text) ?? "fits")")
                shownPairs += shown(text) ? 1 : 0
            }
        }
        #expect(shownPairs > 600, "\(shownPairs)")
        // Only one, and not after anything that is not a letter of those: the second is written out.
        #expect(scalars(escaped("x\u{323}\u{330}")) == scalars("x\u{323}") + scalars(hex(0x330)))
        #expect(scalars(escaped("x\u{330}\u{323}")) == scalars("x\u{323}") + scalars(hex(0x330)) || scalars(escaped("x\u{330}\u{323}")) == scalars("x\u{330}") + scalars(hex(0x323)))
        for text in ["A\u{323}\u{323}", "g\u{323}", "d\u{301}", "7\u{323}", "\u{4E2D}\u{323}", "\u{D55C}\u{323}", "\u{3042}\u{323}", "\u{1F600}\u{323}", " \u{323}", "\u{323}"] {
            #expect(!escaped(text).unicodeScalars.contains { (0x300...0x36F).contains($0.value) }, "\(name(text))")
        }
        #expect(escaped("\n\u{323}") == "\n" + hex(0x323) && escaped("\u{200B}\u{323}") == hex(0x200B, 0x323) && escaped("\t\u{323}") == "⇥ " + hex(0x323))
        #expect(escaped("x\u{323}\u{323}\u{323}\u{323}") == "x\u{323}" + hex(0x323, 0x323, 0x323))
    }

    // MARK: Emoji

    private func regional(_ letters: String) -> String {
        String(String.UnicodeScalarView(letters.unicodeScalars.map { Unicode.Scalar(0x1F1E6 + $0.value - 0x41)! }))
    }

    @Test func everyEmojiSequenceTheCardShowsDrawsInsideItsRow() {
        let pictures = Self.shownScalars.filter { $0.value >= 0x1F000 || (0x2600...0x27BF).contains($0.value) }
        #expect(pictures.count > 1_300)
        let joiner = "\u{200D}", selector = "\u{FE0F}", tones = (0x1F3FB...0x1F3FF).map { String(Unicode.Scalar($0)!) }
        let woman = "\u{1F469}"
        var texts: [String] = []
        for picture in pictures.map(String.init) {
            texts += [picture, picture + selector, picture + "\u{FE0E}", picture + joiner + woman, woman + joiner + picture,
                      picture + selector + joiner + woman, woman + joiner + picture + selector, Array(repeating: picture, count: 5).joined(separator: joiner),
                      Array(repeating: picture + selector, count: 5).joined(separator: joiner)]
            texts += tones.map { picture + $0 }
        }
        for base in ["\u{1F44D}", "\u{1F469}", "\u{1F9D1}", "\u{1F468}"] {
            texts += tones.map { tone in Array(repeating: base + tone, count: 5).joined(separator: joiner) }
        }
        let letters = (0..<26).map { Character(Unicode.Scalar(0x41 + $0)!) }
        texts += letters.flatMap { a in letters.map { regional(String(a) + String($0)) } }
        texts += ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "*"].map { $0 + selector + "\u{20E3}" }
        texts += ["👨‍👩‍👧‍👦", "❤️‍🔥", "🏳️‍🌈", "👁️‍🗨️", "👩🏽‍🤝‍🧑🏻", "🧑‍🧑‍🧒‍🧒", "🇰🇷", "🏴‍☠️", "👩🏽‍⚕️", "1️⃣", "🏳️‍⚧️", "🐻‍❄️", "👩‍⚖️", "🏃‍♀️"]
        let raster = Raster()
        var problems: [String] = [], kept = 0
        for text in texts where shown(text) {
            kept += 1
            if let why = problem(text) { problems.append("\(name(text)) \(why)") }
            else if raster.overflow(text, in: faces[0]) > 1 { problems.append("\(name(text)) paints past the row") }
            if !stable(text) { problems.append("\(name(text)) is changed by normalization") }
        }
        #expect(problems.isEmpty, "\(problems.count): \(problems.prefix(8))")
        #expect(kept > 13_000, "\(kept)")
        // The ones from the reviews, drawn as one picture each, are shown whole.
        for text in ["👨‍👩‍👧‍👦", "❤️‍🔥", "🇰🇷", "1️⃣", "🏳️‍🌈", "👩🏽‍⚕️", "😀", "👍🏽"] {
            #expect(escaped(text) == text, "\(name(text))")
        }
    }

    @Test func aSkinToneRegionalLetterAndKeycapStayOnlyWhereTheyMakeUpAPicture() {
        let flag = regional("KR")
        #expect(escaped(flag) == flag && escaped(flag + flag) == flag + flag)
        #expect(escaped(regional("K")) == hex(0x1F1F0) && escaped("a" + regional("K") + "b") == "a" + hex(0x1F1F0) + "b")
        #expect(escaped(flag + regional("K")) == flag + hex(0x1F1F0) && escaped(regional("KRK")) == flag + hex(0x1F1F0))
        #expect(escaped(regional("KRUSX")) == flag + regional("US") + hex(0x1F1FD))
        // A tone sits on a picture that takes one, once.
        #expect(escaped("\u{1F44D}\u{1F3FD}") == "\u{1F44D}\u{1F3FD}")
        #expect(escaped("\u{1F44D}\u{1F3FD}\u{1F3FD}") == "\u{1F44D}\u{1F3FD}" + hex(0x1F3FD))
        #expect(escaped("\u{1F44D}\u{1F3FD}\u{1F3FF}") == "\u{1F44D}\u{1F3FD}" + hex(0x1F3FF))
        #expect(escaped("\u{1F600}\u{1F3FD}") == "\u{1F600}" + hex(0x1F3FD))
        #expect(escaped("\u{1F3FD}") == hex(0x1F3FD) && escaped("a\u{1F3FD}") == "a" + hex(0x1F3FD))
        #expect(escaped("\u{1F44D}\u{FE0F}\u{1F3FD}") == "\u{1F44D}\u{FE0F}" + hex(0x1F3FD))
        // A keycap is a digit, # or *, the selector and the keycap, in that order.
        #expect(escaped("1\u{20E3}") == "1" + hex(0x20E3) && escaped("\u{20E3}") == hex(0x20E3) && escaped("a\u{FE0F}\u{20E3}") == "a" + hex(0xFE0F, 0x20E3))
        #expect(escaped("1\u{FE0F}\u{20E3}\u{20E3}") == "1\u{FE0F}\u{20E3}" + hex(0x20E3) && escaped("1\u{FE0F}\u{FE0F}\u{20E3}") == "1" + hex(0xFE0F, 0xFE0F, 0x20E3))
        #expect(escaped("\u{1F600}\u{20E3}") == "\u{1F600}" + hex(0x20E3) && escaped("\u{1F600}\u{FE0F}\u{20E3}") == "\u{1F600}\u{FE0F}" + hex(0x20E3))
        #expect(escaped("1\u{FE0F}x") == "1" + hex(0xFE0F) + "x" && escaped("\u{2764}\u{FE0F}\u{20E3}") == "\u{2764}\u{FE0F}" + hex(0x20E3))
    }

    // MARK: What the reviews found

    @Test func theScalarsTheReviewsShowedDrawingOverOtherRowsOrClippedAreWrittenOut() {
        // Tall stacked marks and cuneiform paint over the rows beside them.
        #expect(escaped("ab\u{1DD8}\u{1DD9}c") == "ab" + hex(0x1DD8, 0x1DD9) + "c")
        #expect(escaped("\u{12031}") == hex(0x12031))
        // Unbreakable clusters of conjoining jamo, spacing marks and halfwidth voicing marks clip at the right edge.
        #expect(escaped(String(repeating: "\u{1160}", count: 190)) == String(repeating: hex(0x1160), count: 190))
        #expect(escaped(String(repeating: "\u{1100}", count: 190)) == String(repeating: hex(0x1100), count: 190))
        #expect(escaped("a" + String(repeating: "\u{93E}", count: 300)) == "a" + String(repeating: hex(0x93E), count: 300))
        #expect(escaped("\u{FF76}\u{FF9E}\u{FF9F}") == "\u{FF76}" + hex(0xFF9E, 0xFF9F))
        #expect(escaped("\u{304B}\u{3099}") == "\u{304C}" && escaped("\u{3042}\u{3099}") == "\u{3042}" + hex(0x3099))
        // Bassa Vah draws nothing.
        #expect(escaped((0x16AF0...0x16AF4).map { String(Unicode.Scalar($0)!) }.joined()) == hex(0x16AF0, 0x16AF1, 0x16AF2, 0x16AF3, 0x16AF4))
        // A conjoining jamo that composes is the syllable; one that doesn't is written out.
        #expect(escaped("\u{1112}\u{1161}\u{11AB}") == "\u{D55C}" && escaped("\u{1112}\u{1161}\u{11AB}\u{11AB}") == "\u{D55C}" + hex(0x11AB))
        // The Korean path macOS stored decomposed, and the accented letter typed with a separate accent, read as they were meant.
        let decomposed = "/Users/me/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}/re\u{301}sume\u{301}.txt"
        #expect(scalars(escaped(decomposed)) == scalars("/Users/me/\u{D55C}\u{AE00}/r\u{E9}sum\u{E9}.txt"))
        #expect(scalars(escaped("e\u{301}")) == [0xE9])
    }

    // MARK: Drawn

    private var reviewSamples: [(String, String)] {
        [("stacked-marks", "line one\nab\u{1DD8}\u{1DD9}c\u{1DD8}\u{1DD8}\u{1DD8}d\nline three"),
         ("cuneiform", "before\n\u{12031}\u{12031}\nafter"),
         ("conjoining-jamo", "x " + String(repeating: "\u{1160}", count: 100) + String(repeating: "\u{1100}", count: 90) + " y"),
         ("spacing-marks", "a" + String(repeating: "\u{93E}", count: 300)),
         ("halfwidth-voicing", "\u{FF76}\u{FF9E} \u{FF8A}\u{FF9F} \u{304B}\u{3099} \u{30A6}\u{3099}"),
         ("bassa-vah", "x\u{16AF0}\u{16AF1}\u{16AF2}\u{16AF3}\u{16AF4}y"),
         ("normalization", "kelvin \u{212A} greek-question \u{37E} grave \u{1FEF} ohm \u{2126} angstrom \u{212B}"),
         ("korean-nfd", "ls /Users/me/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}/\u{110B}\u{1175}\u{1105}\u{1161}\u{11A8}\u{1109}\u{1165}.txt"),
         ("latin-nfd", "cat re\u{301}sume\u{301}-nai\u{308}ve.pdf"),
         ("emoji", "family 👨‍👩‍👧‍👦 fire ❤️‍🔥 flag 🇰🇷 key 1️⃣ rainbow 🏳️‍🌈 wave 👋🏽 \u{1F1F0} lone"),
         ("marks", "x\u{323} n\u{303}\u{323} a\u{301}\u{323} A\u{323}\u{323} g\u{323} d\u{301}")]
    }

    @MainActor @Test func theReviewSamplesAreDrawnInsideTheirRows() throws {
        let directory = ProcessInfo.processInfo.environment["PERMISSION_RENDER_DIR"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for (label, text) in reviewSamples {
            let detail = PermissionText.escape(text, multiline: true)
            let prompt = PermissionPrompt(id: UUID(), title: "Run a command", symbol: "terminal", detail: detail, folder: "proj", grant: nil)
            let place = PermissionLayout.Place.card
            let view = PermissionBody(prompt: prompt, showsTitle: true, stacked: true, place: place, gate: PermissionClickGate()) { _ in }
                .frame(width: place.width, height: 150, alignment: .topLeading).padding(10).background(Color.black).environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: place.width + 20, height: 170)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(place.width + 20) * 3, pixelsHigh: 170 * 3, bitsPerSample: 8,
                                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1_000)
            if let directory { try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(label).png")) }
        }
    }
}
