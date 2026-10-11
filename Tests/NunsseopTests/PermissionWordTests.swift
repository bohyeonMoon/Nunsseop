import AppKit
import CoreText
import Foundation
import Testing
@testable import Nunsseop

/// A scalar that reads as ASCII is written out where its word can pass for ASCII, and shown in the words of a language of its own.
struct PermissionWordTests {
    private func hex(_ values: UInt32...) -> String { values.map { String(format: "⟨U+%04X⟩", $0) }.joined() }
    private func escaped(_ text: String) -> String { PermissionText.escape(text, multiline: true) }
    private func name(_ text: String) -> String { text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ") }

    /// Written out at the look-alike; the rest of the line stays.
    @Test func aWordThatCanPassForASCIIHasItsLookalikesWrittenOut() {
        let cases: [(String, String)] = [
            ("rm \u{2010}rf /", "rm " + hex(0x2010) + "rf /"),
            ("git push \u{2011}\u{2011}force", "git push " + hex(0x2011, 0x2011) + "force"),
            ("g\u{456}t status", "g" + hex(0x456) + "t status"),
            ("/etc/pa\u{455}\u{455}wd", "/etc/pa" + hex(0x455, 0x455) + "wd"),
            ("https://github.com\u{3002}evil.com/x.sh", "https://github.com" + hex(0x3002) + "evil.com/x.sh"),
            ("ls \u{3161}la", "ls " + hex(0x3161) + "la"),
            ("rm \u{2014}rf", "rm " + hex(0x2014) + "rf"),
            // A whole word of them reads as ASCII too.
            ("\u{FF52}\u{FF4D}", hex(0xFF52, 0xFF4D)),
            ("\u{FF0F}", hex(0xFF0F)),
            ("\u{2010}", hex(0x2010)),
            ("echo \u{FF0D}\u{FF0D} ok", "echo " + hex(0xFF0D, 0xFF0D) + " ok"),
            ("\u{43E}\u{440}", hex(0x43E, 0x440)),
            // At either end of a word with an ASCII letter or digit, and in the middle.
            ("\u{FF52}m", hex(0xFF52) + "m"), ("m\u{FF52}", "m" + hex(0xFF52)), ("m\u{FF52}m", "m" + hex(0xFF52) + "m"),
            ("7\u{2212}", "7" + hex(0x2212)), ("\u{2212}7", hex(0x2212) + "7"),
            // Pictures that read as ASCII follow the same rule.
            ("a\u{2795}", "a" + hex(0x2795)), ("\u{2795}", hex(0x2795)), ("3 \u{2795} 4", "3 " + hex(0x2795) + " 4"), ("\u{2795}\u{2796}", hex(0x2795, 0x2796)),
        ]
        for (text, expected) in cases { #expect(escaped(text) == expected, "\(name(text))") }
    }

    @Test func aWordInALanguageOfItsOwnIsShownAsItIs() {
        for text in ["\u{30CE}\u{30FC}\u{30C8}", "привет мир", "Καλημέρα", "그리고…", "“안녕”", "テスト（１）", "ㅡㅡ", "A — B", "naïve", "café",
                     "Tiếng Việt", "Ứng dụng", "です。", "一", "ー", "—", "ㅡ", "・", "‒–—", "\u{2795}\u{AC00}", "한글。", "日本語。中文", "\u{3008}文\u{3009}",
                     "ls /Users/me/한글/문서.txt", "echo ノート ok"] {
            #expect(escaped(text) == text, "\(name(text))")
        }
        // What the word does not hold is as before.
        #expect(escaped("ノ\u{200B}ー") == "ノ" + hex(0x200B) + "ー")
    }

    /// The word is the input between ASCII space, tab, CR and LF; nothing else splits it.
    @Test func aWordEndsAtOneOfFourSeparatorsAndAtNothingElse() {
        // The separator keeps the neighbour's letter out of the word.
        #expect(escaped("A \u{30FC}") == "A \u{30FC}")
        #expect(escaped("A\t\u{30FC}") == "A⇥ \u{30FC}")
        #expect(escaped("A\n\u{30FC}") == "A\n\u{30FC}")
        #expect(escaped("A\r\n\u{30FC}") == "A\n\u{30FC}")
        #expect(escaped("A\r\u{30FC}") == "A" + hex(0xD) + "\u{30FC}")
        #expect(escaped("\u{30FC}\tA") == "\u{30FC}⇥ A")
        #expect(PermissionText.escape("A\n\u{30FC}", multiline: false) == "A" + hex(0xA) + "\u{30FC}")
        // And the same word with one of the other spaces in place is one word.
        for space in ["\u{3000}", "\u{A0}", "\u{2003}", "\u{200B}", "\u{2028}", "\u{85}", "\u{0B}", "\u{0C}"] {
            let scalar = space.unicodeScalars.first!.value
            #expect(escaped("ls" + space + "\u{3161}la") == "ls" + hex(scalar) + hex(0x3161) + "la", "\(name(space))")
            // The letters are all on the other side of the space: the word is one only if the space is part of it.
            #expect(escaped("ls" + space + "\u{3161}") == "ls" + hex(scalar) + hex(0x3161), "\(name(space))")
            #expect(escaped("\u{3161}" + space + "ls") == hex(0x3161) + hex(scalar) + "ls", "\(name(space))")
            #expect(escaped("\u{FF52}" + space + "\u{FF4D}x") == hex(0xFF52) + hex(scalar) + hex(0xFF4D) + "x", "\(name(space))")
        }
        // One word of look-alikes beside another with a letter: each is judged on its own.
        #expect(escaped("\u{FF52}\u{FF4D} ノート") == hex(0xFF52, 0xFF4D) + " ノート")
        #expect(escaped("ノート rm\u{FF0D}rf") == "ノート rm" + hex(0xFF0D) + "rf")
        // The word is the input's, not the escaped text's: what is written out holds letters and digits, and does not make a neighbour ASCII.
        #expect(escaped("\u{30CE}\u{200B}\u{30FC}") == "\u{30CE}" + hex(0x200B) + "\u{30FC}")
        #expect(escaped("\u{FF52}\u{200B}\u{FF4D}") == "\u{FF52}" + hex(0x200B) + "\u{FF4D}")
        // The same for a scalar whose own normal form is another: the Kelvin sign is written out, and is no ASCII K in the word.
        #expect(escaped("\u{30CE}\u{212A}\u{30FC}") == "\u{30CE}" + hex(0x212A) + "\u{30FC}")
        // A scalar that is written out is not ASCII to the other rule either: a letter beside it in a word still counts for the first.
        #expect(escaped("r\u{200B}\u{FF4D}") == "r" + hex(0x200B) + hex(0xFF4D))
    }

    /// Scalars the checker misses that draw like ASCII punctuation: they count only beside an ASCII letter or digit.
    @Test func scalarsDrawnLikePunctuationAreWrittenOutBesideAnASCIILetterOrDigitOnly() {
        let extras: [UInt32] = [0x3161, 0x3163, 0x4E28, 0x4E00, 0x30FC, 0xFF70, 0x3021, 0x2758, 0x2014, 0x2015, 0xB7, 0x3002, 0xFF61, 0x3008, 0x3009]
        for value in extras {
            let text = String(Unicode.Scalar(value)!), label = "U+" + String(value, radix: 16, uppercase: true)
            // With a letter or a digit anywhere in the word.
            #expect(escaped("a" + text) == "a" + hex(value), "\(label)")
            #expect(escaped(text + "a") == hex(value) + "a", "\(label)")
            #expect(escaped("9" + text + "z") == "9" + hex(value) + "z", "\(label)")
            #expect(escaped("-" + text + "_5") == "-" + hex(value) + "_5", "\(label)")
            // Alone, among themselves, among punctuation, and in a word of another script.
            #expect(escaped(text) == text, "\(label)")
            #expect(escaped(text + text) == text + text, "\(label)")
            #expect(escaped(text + "-/" + text) == text + "-/" + text, "\(label)")
            #expect(escaped(text + "한") == text + "한", "\(label)")
            #expect(escaped("한" + text + "글") == "한" + text + "글", "\(label)")
            #expect(escaped("한 " + text + " a") == "한 " + text + " a", "\(label)")
        }
        // Look-alikes of the checker still follow the whole-word rule, with these beside them not counting.
        #expect(escaped("\u{2012}\u{2014}") == "\u{2012}\u{2014}")
        #expect(escaped("\u{2012}\u{2013}\u{2014}") == "\u{2012}\u{2013}\u{2014}")
        #expect(escaped("\u{2012}\u{2013}") == hex(0x2012, 0x2013))
        // The corner brackets that look like the marker of an escape are written out beside a letter, so a fake one can't be built.
        #expect(escaped("\u{3008}U+202E\u{3009}") == hex(0x3008) + "U+202E" + hex(0x3009))
        #expect(escaped("⟨U+202E⟩") == "⟨U+27E8⟩U+202E⟨U+27E9⟩")
    }

    /// Every look-alike the checker finds, beside an ASCII digit, is written out whatever the language; none is lost in the word rule.
    @Test func everyLookalikeBesideAnASCIIDigitIsWrittenOut() throws {
        let lookalike = try asciiLookalikes()
        var checked = 0, shownAlone = 0
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), lookalike(scalar) != nil else { continue }
            let text = "7" + String(scalar)
            guard text.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(text.unicodeScalars) else { continue }
            #expect(escaped(text) == "7" + hex(value), "U+\(String(value, radix: 16, uppercase: true))")
            // Alone it is a word that reads as ASCII, whatever its script.
            if escaped(String(scalar)) == String(scalar) { shownAlone += 1 }
            checked += 1
        }
        #expect(checked > 1_000, "\(checked)")
        #expect(shownAlone == 0, "\(shownAlone)")
    }

    // MARK: Emoji controls

    private func drawing(_ text: String) -> [String] { codeDrawing(text) }

    private func changes(_ picture: String, with control: String) -> Bool { drawing(picture) != drawing(picture + control) }

    /// The pictures the card shows by themselves, as the scalars they are.
    private var pictures: [Unicode.Scalar] {
        (UInt32(0x2600)...0x1FAFF).compactMap { Unicode.Scalar($0) }.filter {
            ($0.value <= 0x27BF || $0.value >= 0x1F000) && $0.properties.isEmoji && !$0.properties.isEmojiModifier
                && !(0x1F1E6...0x1F1FF).contains($0.value) && escaped(String($0)) == String($0)
        }
    }

    @Test func aSelectorOrToneStaysOnlyWhereCoreTextDrawsTheLetterDifferentlyWithIt() {
        let colour = "\u{FE0F}", text = "\u{FE0E}"
        var kept = 0, written = 0, textKept = 0, textWritten = 0, tonesKept = 0
        for picture in pictures {
            let base = String(picture), label = "U+" + String(picture.value, radix: 16, uppercase: true)
            // The colour selector: not after a picture that is in colour already, and not where the drawing is the same.
            let wantsColour = !picture.properties.isEmojiPresentation && changes(base, with: colour)
            #expect(escaped(base + colour) == base + (wantsColour ? colour : hex(0xFE0F)), "\(label)")
            if wantsColour { kept += 1 } else { written += 1 }
            // The text selector: where the drawing is the same, it is written out as well.
            let wantsText = changes(base, with: text)
            #expect(escaped(base + text) == base + (wantsText ? text : hex(0xFE0E)), "\(label)")
            if wantsText { textKept += 1 } else { textWritten += 1 }
            if picture.properties.isEmojiModifierBase {
                for tone in 0x1F3FB...0x1F3FF {
                    let skin = String(Unicode.Scalar(UInt32(tone))!)
                    #expect(escaped(base + skin) == base + (changes(base, with: skin) ? skin : hex(UInt32(tone))), "\(label)")
                    tonesKept += changes(base, with: skin) ? 1 : 0
                }
            }
        }
        #expect(kept > 50 && written > 1_000 && textKept > 10 && textWritten > 1_000 && tonesKept > 100, "\(kept) \(written) \(textKept) \(textWritten) \(tonesKept)")
    }

    @Test func theControlsOfPicturesTheFontDrawsTheSameWithAndWithoutAreWrittenOut() {
        // The thermometer is drawn in colour without the selector; the heart, the sun and the smile are text without it.
        #expect(drawing("\u{1F321}") == drawing("\u{1F321}\u{FE0F}"))
        #expect(escaped("\u{1F321}\u{FE0F}") == "\u{1F321}" + hex(0xFE0F))
        #expect(escaped("\u{1F321}\u{FE0E}") == "\u{1F321}" + hex(0xFE0E))
        #expect(drawing("\u{263A}") == drawing("\u{263A}\u{FE0E}"))
        #expect(escaped("\u{263A}\u{FE0E}") == "\u{263A}" + hex(0xFE0E))
        #expect(escaped("\u{2764}\u{FE0E}") == "\u{2764}" + hex(0xFE0E))
        #expect(escaped("\u{2714}\u{FE0E}") == "\u{2714}" + hex(0xFE0E))
        #expect(escaped("\u{1F4C1}\u{FE0F}") == "\u{1F4C1}" + hex(0xFE0F))
        // Where the selector turns the drawing into the other one, it stays.
        #expect(drawing("\u{2764}") != drawing("\u{2764}\u{FE0F}"))
        #expect(escaped("\u{2764}\u{FE0F}") == "\u{2764}\u{FE0F}" && escaped("\u{26A0}\u{FE0F}") == "\u{26A0}\u{FE0F}")
        #expect(drawing("\u{2614}") != drawing("\u{2614}\u{FE0E}"))
        #expect(escaped("\u{2614}\u{FE0E}") == "\u{2614}\u{FE0E}")
        // A tone that the font joins to the hand, and the rest of what renders.
        for text in ["\u{1F44D}\u{1F3FD}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "1\u{FE0F}\u{20E3}", "#\u{FE0F}\u{20E3}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
                     "\u{1F4C1}", "\u{1F600}", "\u{1F1F0}\u{1F1F7}"] {
            #expect(escaped(text) == text, "\(name(text))")
        }
        // The rainbow flag's selector follows the thermometer's: it draws the same without it, so it is written out, and the joiner with it.
        #expect(drawing("\u{1F3F3}") == drawing("\u{1F3F3}\u{FE0F}"))
        #expect(escaped("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}") == "\u{1F3F3}" + hex(0xFE0F, 0x200D) + "\u{1F308}")
        #expect(drawing("\u{1F3F3}\u{200D}\u{1F308}").count == 1 && escaped("\u{1F3F3}\u{200D}\u{1F308}") == "\u{1F3F3}\u{200D}\u{1F308}")
    }

    /// A joiner is kept only before a picture that is shown: one that reads as ASCII, in a word that can pass for ASCII, is written out.
    @Test func aJoinerBeforeAPictureThatIsWrittenOutIsWrittenOutToo() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(drawing(family).count == 1)
        #expect(escaped("a" + family + "\u{200D}\u{2795}") == "a" + family + hex(0x200D, 0x2795))
        #expect(escaped("a" + family) == "a" + family)
        // Without a letter the picture is shown, and the whole is no picture of the font's: every joiner goes.
        #expect(escaped(family + "\u{200D}\u{2795}") == "\u{1F468}" + hex(0x200D) + "\u{1F469}" + hex(0x200D) + "\u{1F467}" + hex(0x200D) + "\u{2795}")
    }

    @Test func aKeycapKeepsItsSelectorAndNothingElseDoes() {
        for digit in ["0", "1", "5", "9", "#", "*"] { #expect(escaped(digit + "\u{FE0F}\u{20E3}") == digit + "\u{FE0F}\u{20E3}", "\(digit)") }
        #expect(escaped("1\u{FE0F}") == "1" + hex(0xFE0F) && escaped("a\u{FE0F}\u{20E3}") == "a" + hex(0xFE0F, 0x20E3))
    }
}
