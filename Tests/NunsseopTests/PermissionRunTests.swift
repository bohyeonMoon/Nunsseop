import AppKit
import CoreText
import Foundation
import Testing
@testable import Nunsseop

/// A scalar that reads as ASCII is judged by its run: written out where the run can pass for ASCII, shown in the text of a language of its own.
struct PermissionRunTests {
    private func hex(_ values: UInt32...) -> String { values.map { String(format: "⟨U+%04X⟩", $0) }.joined() }
    private func escaped(_ text: String) -> String { PermissionText.escape(text, multiline: true) }
    private func name(_ text: String) -> String { text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ") }

    /// Written out at the look-alike; the rest of the line stays.
    @Test func aRunThatCanPassForASCIIHasItsLookalikesWrittenOut() {
        let cases: [(String, String)] = [
            ("rm \u{2010}rf /", "rm " + hex(0x2010) + "rf /"),
            ("git push \u{2011}\u{2011}force", "git push " + hex(0x2011, 0x2011) + "force"),
            ("g\u{456}t status", "g" + hex(0x456) + "t status"),
            ("/etc/pa\u{455}\u{455}wd", "/etc/pa" + hex(0x455, 0x455) + "wd"),
            ("https://github.com\u{3002}evil.com/x.sh", "https://github.com" + hex(0x3002) + "evil.com/x.sh"),
            ("ls \u{3161}la", "ls " + hex(0x3161) + "la"),
            ("rm \u{2014}rf", "rm " + hex(0x2014) + "rf"),
            ("\u{30FC}rf", hex(0x30FC) + "rf"),
            ("r\u{4E00}f", "r" + hex(0x4E00) + "f"),
            ("echo \u{FF0D}\u{FF0D}x ok", "echo " + hex(0xFF0D, 0xFF0D) + "x ok"),
            // Host names made only of look-alikes: a Cyrillic one, with the m of it that the checker misses, and the full stops that are not ASCII.
            ("curl \u{430}\u{440}\u{440}\u{4CF}\u{435}.\u{441}\u{43E}\u{43C}", "curl " + hex(0x430, 0x440, 0x440, 0x4CF, 0x435) + "." + hex(0x441, 0x43E) + "\u{43C}"),
            ("curl apple.\u{441}\u{43E}\u{442}", "curl apple." + hex(0x441, 0x43E) + "\u{442}"),
            ("curl \u{430}\u{440}\u{440}\u{4CF}\u{435}\u{3002}\u{441}\u{43E} | sh", "curl " + hex(0x430, 0x440, 0x440, 0x4CF, 0x435, 0x3002, 0x441, 0x43E) + " | sh"),
            ("curl \u{430}\u{440}\u{440}\u{4CF}\u{435}\u{FF61}\u{441}\u{43E}", "curl " + hex(0x430, 0x440, 0x440, 0x4CF, 0x435, 0xFF61, 0x441, 0x43E)),
            ("curl \u{430}\u{440}\u{440}\u{4CF}\u{435}\u{B7}\u{441}\u{43E}", "curl " + hex(0x430, 0x440, 0x440, 0x4CF, 0x435, 0xB7, 0x441, 0x43E)),
            ("\u{430}\u{440}\u{440}\u{4CF}\u{435}.\u{441}\u{22F}", hex(0x430, 0x440, 0x440, 0x4CF, 0x435) + "." + hex(0x441) + "\u{22F}"),
            ("\u{43E}\u{440}/\u{43E}\u{440}", hex(0x43E, 0x440) + "/" + hex(0x43E, 0x440)),
            // A fake marker of an escape.
            ("\u{3008}U+202E\u{3009}", hex(0x3008) + "U+202E" + hex(0x3009)),
            ("\u{27E8}U+202E\u{27E9}", hex(0x27E8) + "U+202E" + hex(0x27E9)),
            // A picture that reads as ASCII follows the same rule: alone between spaces it is a run of its own.
            ("a\u{2795}", "a" + hex(0x2795)), ("\u{2795}\u{2796}", "\u{2795}\u{2796}"), ("3 \u{2795} 4", "3 \u{2795} 4"), ("3\u{2795}4", "3" + hex(0x2795) + "4"),
        ]
        for (text, expected) in cases { #expect(escaped(text) == expected, "\(name(text))") }
    }

    @Test func aRunOfALanguageOfItsOwnIsShownAsItIs() {
        for text in ["\u{30CE}\u{30FC}\u{30C8}", "привет мир", "Καλημέρα ο άνθρωπος", "Он пришёл а она ушла. хор сера как", "а", "хор", "сера", "ο", "그리고…", "“안녕”",
                     "テスト（１）", "ㅡㅡ", "A — B", "naïve", "café", "Tiếng Việt", "Ứng dụng", "です。", "一", "ー", "—", "ㅡ", "・", "‒–", "\u{2795}\u{AC00}", "한글。",
                     "日本語。中文", "\u{3008}文\u{3009}", "ls /Users/me/한글/문서.txt", "echo ノート ok",
                     // Latin words among text that has none: the words of the other language stay whole.
                     "サーバーでnpmを実行（テスト）", "请运行npm install命令，然后一次性完成。", "有一个bug", "Pythonでプログラム！", "echo 안녕 && ls 한글/ノート",
                     // Alone, a look-alike is harmless: no shell has a command or a flag of it, and the full width forms are visibly wide.
                     "\u{FF52}\u{FF4D}", "\u{FF0F}", "\u{2010}", "\u{2212}", "\u{43E}\u{440}", "\u{3002}", "echo \u{FF52}\u{FF4D} ok"] {
            #expect(escaped(text) == text, "\(name(text))")
        }
        // What the text does not hold is as before.
        #expect(escaped("ノ\u{200B}ー") == "ノ" + hex(0x200B) + "ー")
    }

    /// A run is what is made of ASCII letters and digits, ASCII punctuation and look-alikes; anything else ends it.
    @Test func aRunEndsAtAnythingThatIsNoneOfThose() {
        let (a, o, c, m, ya) = ("\u{430}", "\u{43E}", "\u{441}", "\u{43C}", "\u{44F}")
        // A letter that reads as no ASCII one, in the middle: each side is judged without the other.
        #expect(escaped("x" + a + ya + o) == "x" + hex(0x430) + ya + o)
        #expect(escaped(a + ya + o + "x") == a + ya + hex(0x43E) + "x")
        #expect(escaped(a + m + c + "x") == a + m + hex(0x441) + "x")
        // A look-alike at the start and at the end of a run with an ASCII letter.
        #expect(escaped(a + "x") == hex(0x430) + "x" && escaped("x" + a) == "x" + hex(0x430) && escaped(a + "x" + a) == hex(0x430) + "x" + hex(0x430))
        // Spaces, tabs, CR and LF end a run; CR LF is one break.
        #expect(escaped("x " + a) == "x " + a && escaped("x\t" + a) == "x⇥ " + a && escaped("x\n" + a) == "x\n" + a && escaped("x\r\n" + a) == "x\n" + a)
        #expect(escaped("x\r" + a) == "x" + hex(0xD) + a && escaped(a + "\tx") == a + "⇥ x" && escaped(a + "\r\nx") == a + "\nx")
        #expect(PermissionText.escape("x\n" + a, multiline: false) == "x" + hex(0xA) + a)
        #expect(escaped(a + ".\n." + c) == a + ".\n." + c && escaped(a + ".\t." + c) == a + ".⇥ ." + c && escaped(a + ". ." + c) == a + ". ." + c)
        // Another space is no member of it, and ends it too: the ideographic space, no-break space, em space, zero-width space, line separator and the controls.
        for space in ["\u{3000}", "\u{A0}", "\u{2003}", "\u{200B}", "\u{2028}", "\u{85}", "\u{0B}", "\u{0C}"] {
            let scalar = space.unicodeScalars.first!.value
            #expect(escaped("ls" + space + "\u{3161}") == "ls" + hex(scalar) + "\u{3161}", "\(name(space))")
            #expect(escaped("\u{3161}" + space + "ls") == "\u{3161}" + hex(scalar) + "ls", "\(name(space))")
            // The look-alike is still attached to the letters on its other side.
            #expect(escaped("ls" + space + "\u{3161}la") == "ls" + hex(scalar) + hex(0x3161) + "la", "\(name(space))")
            #expect(escaped("\u{FF52}" + space + "\u{FF4D}x") == "\u{FF52}" + hex(scalar) + hex(0xFF4D) + "x", "\(name(space))")
        }
        // A scalar that is written out ends it as well, and is no letter of the run: the Kelvin sign, a direction mark.
        #expect(escaped("\u{30CE}\u{200B}\u{30FC}") == "\u{30CE}" + hex(0x200B) + "\u{30FC}")
        #expect(escaped("\u{FF52}\u{200B}\u{FF4D}") == "\u{FF52}" + hex(0x200B) + "\u{FF4D}")
        #expect(escaped("\u{30CE}\u{212A}\u{30FC}") == "\u{30CE}" + hex(0x212A) + "\u{30FC}")
        #expect(escaped("r\u{200B}\u{FF4D}") == "r" + hex(0x200B) + "\u{FF4D}")
        #expect(escaped("\u{FF4D}\u{200E}r") == "\u{FF4D}" + hex(0x200E) + "r")
        #expect(escaped("x\u{212A}\u{FF4D}") == "x" + hex(0x212A) + "\u{FF4D}")
        #expect(escaped("\u{FF4D}\u{FE0F}r") == "\u{FF4D}" + hex(0xFE0F) + "r")
        // A picture ends it, and so does a combining mark that is written out.
        #expect(escaped("\u{FF4D}\u{1F600}r") == "\u{FF4D}\u{1F600}r" && escaped("r\u{1F600}\u{FF4D}") == "r\u{1F600}\u{FF4D}")
        #expect(escaped("\u{FF4D}\u{1F44D}\u{1F3FD}r") == "\u{FF4D}\u{1F44D}\u{1F3FD}r")
        #expect(escaped("\u{FF4D}\u{1F600}") == "\u{FF4D}\u{1F600}" && escaped("r\u{FF4D}") == "r" + hex(0xFF4D))
        #expect(escaped("\u{FF4D}\u{323}r") == "\u{FF4D}" + hex(0x323) + "r")
        #expect(escaped("m\u{323}\u{FF4D}") == "m\u{323}\u{FF4D}")
    }

    /// Punctuation with a look-alike on each side makes a run a dotted, slashed or joined name; at its edge, or beside ASCII punctuation, it makes none.
    @Test func punctuationBetweenTwoLookalikesMakesTheRunAName() {
        let (a, o, c) = ("\u{430}", "\u{43E}", "\u{441}")
        // ASCII punctuation between two look-alikes: all the run's look-alikes go, and the punctuation stays as it is.
        for glue in [".", "/", "-", "_", ":", "@", "\\", "~", "%", "&", "|", ";", "#", "$", "=", "+", "*", "?", "!", ",", "<", ">", "(", ")", "[", "]", "{", "}", "'", "\"", "`", "^"] {
            #expect(escaped(a + glue + o) == hex(0x430) + glue + hex(0x43E), "\(glue)")
            #expect(escaped(a + c + glue + o + c) == hex(0x430, 0x441) + glue + hex(0x43E, 0x441), "\(glue)")
            // At the edge, or with ASCII punctuation beside it or a letter that reads as no ASCII one, it is none.
            #expect(escaped(glue + a + o) == glue + a + o && escaped(a + o + glue) == a + o + glue, "\(glue)")
            #expect(escaped(glue + a + glue) == glue + a + glue, "\(glue)")
            #expect(escaped(a + glue + glue + o) == a + glue + glue + o, "\(glue)")
            #expect(escaped(a + glue + "\u{44F}" + o) == a + glue + "\u{44F}" + o, "\(glue)")
        }
        // A look-alike that is punctuation or a symbol between two look-alikes, whether those are letters or punctuation themselves.
        for mark in ["\u{3002}", "\u{FF61}", "\u{B7}", "\u{2010}", "\u{FF0F}", "\u{2014}", "\u{2795}", "\u{2758}"] {
            #expect(escaped(a + mark + o) == hex(0x430) + hex(UInt32(mark.unicodeScalars.first!.value)) + hex(0x43E), "\(name(mark))")
            #expect(escaped(a + mark + mark + o) == hex(0x430) + String(repeating: hex(UInt32(mark.unicodeScalars.first!.value)), count: 2) + hex(0x43E), "\(name(mark))")
            #expect(escaped(mark + mark + mark) == String(repeating: hex(UInt32(mark.unicodeScalars.first!.value)), count: 3), "\(name(mark))")
            #expect(escaped(mark + mark) == mark + mark && escaped(mark + a) == mark + a && escaped(a + mark) == a + mark, "\(name(mark))")
        }
        // A letter or a digit between them is none: strokes, the prolonged sound mark, full width digits.
        for letter in ["\u{3161}", "\u{30FC}", "\u{4E00}", "\u{30CE}", "\u{FF11}", "\u{FF41}"] {
            #expect(escaped(a + letter + o) == a + letter + o && escaped(letter + letter + letter) == letter + letter + letter, "\(name(letter))")
        }
        // Two names, one of them with the punctuation of a name, are judged one by one.
        #expect(escaped(a + "." + o + " " + a + o + " " + c + "/") == hex(0x430) + "." + hex(0x43E) + " " + a + o + " " + c + "/")
        // A name that holds a letter that reads as no ASCII one is cut there.
        #expect(escaped(a + "." + o + "\u{44F}" + c + "." + a) == hex(0x430) + "." + hex(0x43E) + "\u{44F}" + hex(0x441) + "." + hex(0x430))
        #expect(escaped(a + "." + "\u{44F}" + "." + o) == a + "." + "\u{44F}" + "." + o)
        // Full width and ideographic punctuation of a sentence is not a name.
        #expect(escaped("テスト（１）") == "テスト（１）" && escaped("（１）") == "（１）")
        #expect(escaped("（（１））") == hex(0xFF08, 0xFF08, 0xFF11, 0xFF09, 0xFF09))
    }

    /// The scalars drawn like ASCII punctuation that the checker misses count with the rest.
    @Test func scalarsDrawnLikePunctuationAreJudgedLikeTheLookalikesOfTheChecker() {
        let extras: [UInt32] = [0x3161, 0x3163, 0x4E28, 0x4E00, 0x30FC, 0xFF70, 0x3021, 0x2758, 0x2014, 0x2015, 0xB7, 0x3002, 0xFF61, 0x3008, 0x3009]
        for value in extras {
            let text = String(Unicode.Scalar(value)!), label = "U+" + String(value, radix: 16, uppercase: true)
            // With a letter or a digit anywhere in the run.
            #expect(escaped("a" + text) == "a" + hex(value), "\(label)")
            #expect(escaped(text + "a") == hex(value) + "a", "\(label)")
            #expect(escaped("9" + text + "z") == "9" + hex(value) + "z", "\(label)")
            #expect(escaped("-" + text + "_5") == "-" + hex(value) + "_5", "\(label)")
            // By themselves, among themselves, among ASCII punctuation, and in the text of another script.
            #expect(escaped(text) == text, "\(label)")
            #expect(escaped(text + text) == text + text, "\(label)")
            #expect(escaped(text + "-/" + text) == text + "-/" + text, "\(label)")
            #expect(escaped(text + "한") == text + "한", "\(label)")
            #expect(escaped("한" + text + "글") == "한" + text + "글", "\(label)")
            #expect(escaped("한 " + text + " a") == "한 " + text + " a", "\(label)")
            // Between look-alikes of the checker.
            #expect(escaped("\u{43E}" + text + "\u{43E}") == (isLetterOrNumber(value) ? "\u{43E}" + text + "\u{43E}" : hex(0x43E, value, 0x43E)), "\(label)")
        }
        #expect(escaped("\u{2012}\u{2014}") == "\u{2012}\u{2014}" && escaped("\u{2012}\u{2013}\u{2014}") == hex(0x2012, 0x2013, 0x2014))
        #expect(escaped("\u{2012}\u{2013}") == "\u{2012}\u{2013}")
    }

    private func isLetterOrNumber(_ value: UInt32) -> Bool {
        switch Unicode.Scalar(value)!.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Every look-alike the checker finds, beside an ASCII digit, is written out whatever the language; none is lost to the run rule.
    @Test func everyLookalikeBesideAnASCIIDigitIsWrittenOut() throws {
        let lookalike = try asciiLookalikes()
        var checked = 0, shownAlone = 0
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), lookalike(scalar) != nil else { continue }
            let text = "7" + String(scalar)
            guard text.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(text.unicodeScalars) else { continue }
            #expect(escaped(text) == "7" + hex(value), "U+\(String(value, radix: 16, uppercase: true))")
            #expect(escaped(String(scalar) + "7") == hex(value) + "7", "U+\(String(value, radix: 16, uppercase: true))")
            if escaped(String(scalar)) == String(scalar) { shownAlone += 1 }
            checked += 1
        }
        #expect(checked > 1_000, "\(checked)")
        #expect(shownAlone > 300, "\(shownAlone)")
    }

    /// For every look-alike that is shown by itself: with punctuation between two of them, or two of them round a third that is punctuation, the run goes.
    @Test func everyShownLookalikeIsJudgedByThePunctuationBetweenItsNeighbours() {
        var letters = 0, marks = 0
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), PermissionText.hasLookalike(String(scalar)), escaped(String(scalar)) == String(scalar) else { continue }
            let text = String(scalar), label = "U+" + String(value, radix: 16, uppercase: true)
            // A dot between two of them.
            #expect(escaped(text + "." + text) == hex(value) + "." + hex(value), "\(label)")
            #expect(escaped(text + ".") == text + "." && escaped("." + text) == "." + text && escaped(text + ".." + text) == text + ".." + text, "\(label)")
            // Three of them in a row: the middle one decides, by being punctuation or a symbol.
            if isLetterOrNumber(value) {
                letters += 1
                #expect(escaped(text + text + text) == text + text + text, "\(label)")
            } else {
                marks += 1
                #expect(escaped(text + text + text) == hex(value, value, value), "\(label)")
            }
            #expect(escaped(text + text) == text + text, "\(label)")
        }
        #expect(letters > 200 && marks > 100, "\(letters) \(marks)")
    }

    @Test func aRuleOfTheAlwaysAllowButtonHoldsNoScalarThatReadsAsASCII() {
        for text in ["\u{43E}", "\u{FF52}", "\u{2010}", "\u{3002}", "\u{30CE}", "\u{30FC}", "\u{4E00}", "\u{2122}", "\u{2026}", "Bash(echo ノート)", "a\u{FF0F}", "有一个bug"] {
            #expect(PermissionText.hasLookalike(text), "\(name(text))")
        }
        for text in ["", "npm test", "echo 안녕", "ls /Users/me/한글/문서.txt", "echo r\u{E9}sum\u{E9} \u{D55C}\u{AE00} \u{65E5}\u{672C}", "\u{43C}\u{442}", "请运行npm"] {
            #expect(!PermissionText.hasLookalike(text), "\(name(text))")
        }
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
        // The rainbow flag's selector draws the same without it, as the thermometer's does: by itself it is written out, and in the sequence the font draws as
        // one it stays with the joiner. Where the sequence is not drawn as one, it goes with the joiner.
        #expect(drawing("\u{1F3F3}") == drawing("\u{1F3F3}\u{FE0F}") && drawing("\u{1F321}") == drawing("\u{1F321}\u{FE0F}"))
        #expect(escaped("\u{1F3F3}\u{FE0F}") == "\u{1F3F3}" + hex(0xFE0F) && escaped("\u{1F3F3}\u{FE0F}x") == "\u{1F3F3}" + hex(0xFE0F) + "x")
        #expect(codeDrawing("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}").count == 1 && escaped("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}") == "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}")
        #expect(escaped("\u{1F3F3}\u{FE0F}\u{200D}\u{1F34E}") == "\u{1F3F3}" + hex(0xFE0F, 0x200D) + "\u{1F34E}")
        #expect(escaped("\u{1F321}\u{FE0F}\u{200D}\u{1F321}\u{FE0F}") == "\u{1F321}" + hex(0xFE0F, 0x200D) + "\u{1F321}" + hex(0xFE0F))
        #expect(drawing("\u{1F3F3}\u{200D}\u{1F308}").count == 1 && escaped("\u{1F3F3}\u{200D}\u{1F308}") == "\u{1F3F3}\u{200D}\u{1F308}")
        // The sequences of the standard that hold a selector are whole: the flags, the person lifting weights, the eye in the speech bubble, the face in the clouds.
        for text in ["🏳️‍🌈", "🏳️‍⚧️", "🏋️‍♀️", "👁️‍🗨️", "😶‍🌫️", "❤️‍🔥", "🐻‍❄️", "🏴‍☠️", "🧔‍♂️"] {
            #expect(escaped(text) == text, "\(name(text))")
            // In the middle of a line too.
            #expect(escaped("ls " + text + " ok") == "ls " + text + " ok", "\(name(text))")
        }
        // A selector after a picture in colour already goes even inside a sequence the font draws as one.
        #expect(escaped("\u{1F600}\u{FE0F}\u{200D}\u{1F32B}") == "\u{1F600}" + hex(0xFE0F, 0x200D) + "\u{1F32B}")
    }

    /// A joiner is kept only before a picture that is shown: one that reads as ASCII, in a run that can pass for ASCII, is written out.
    @Test func aJoinerBeforeAPictureThatIsWrittenOutIsWrittenOutToo() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(drawing(family).count == 1)
        #expect(escaped(family + "\u{200D}\u{2795}x") == family + hex(0x200D, 0x2795) + "x")
        #expect(escaped(family) == family && escaped("a" + family) == "a" + family)
        // Where the picture is shown, the whole is no picture of the font's: every joiner goes.
        #expect(escaped(family + "\u{200D}\u{2795}") == "\u{1F468}" + hex(0x200D) + "\u{1F469}" + hex(0x200D) + "\u{1F467}" + hex(0x200D) + "\u{2795}")
    }

    @Test func aKeycapKeepsItsSelectorAndNothingElseDoes() {
        for digit in ["0", "1", "5", "9", "#", "*"] { #expect(escaped(digit + "\u{FE0F}\u{20E3}") == digit + "\u{FE0F}\u{20E3}", "\(digit)") }
        #expect(escaped("1\u{FE0F}") == "1" + hex(0xFE0F) && escaped("a\u{FE0F}\u{20E3}") == "a" + hex(0xFE0F, 0x20E3))
    }
}
