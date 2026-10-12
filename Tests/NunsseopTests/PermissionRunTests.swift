import AppKit
import CoreText
import Foundation
import Testing
@testable import Nunsseop

/// What reads as ASCII is written out only in the certain cases: a letter of another script in a run with an ASCII letter or digit, and a
/// punctuation look-alike where it can change what a command does. Anything else is shown, and `PermissionChipTests` has the card say so with a chip.
struct PermissionRunTests {
    private func hex(_ values: UInt32...) -> String { values.map { String(format: "⟨U+%04X⟩", $0) }.joined() }
    private func escaped(_ text: String) -> String { PermissionText.escape(text, multiline: true) }
    private func name(_ text: String) -> String { text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ") }

    private func check(_ cases: [(String, String)]) {
        for (text, expected) in cases { #expect(escaped(text) == expected, "\(name(text))") }
    }

    private func checkShown(_ texts: [String]) {
        for text in texts { #expect(escaped(text) == text.precomposedStringWithCanonicalMapping, "\(name(text))") }
    }

    // MARK: A1, letters of another script among ASCII ones

    /// A Cyrillic or Greek letter, a full width Latin one, or a Latin one that ICU calls a look-alike, in a run with an ASCII letter or digit: written
    /// out at those scalars, and nowhere else.
    @Test func aLetterOfAnotherScriptInARunWithASCIIIsWrittenOut() {
        check([
            ("\u{43F}pm install", hex(0x43F) + "pm install"),
            ("https://registry.\u{43F}pmjs.org", "https://registry." + hex(0x43F) + "pmjs.org"),
            ("g\u{456}t status", "g" + hex(0x456) + "t status"),
            ("/etc/pa\u{455}\u{455}wd", "/etc/pa" + hex(0x455, 0x455) + "wd"),
            ("curl apple.\u{441}\u{43E}\u{43C}", "curl apple." + hex(0x441, 0x43E, 0x43C)),
            ("\u{FF52}m -rf", hex(0xFF52) + "m -rf"), ("r\u{FF4D}", "r" + hex(0xFF4D)), ("\u{FF15}a", hex(0xFF15) + "a"),
            // Greek and Cyrillic letters that are no look-alikes at all go the same way: the script is what is judged.
            ("\u{39B}pm \u{452}pm \u{45B}pm \u{44F}x", hex(0x39B) + "pm " + hex(0x452) + "pm " + hex(0x45B) + "pm " + hex(0x44F) + "x"),
            // A Latin letter the checker calls a look-alike: the dotless i, the ordinal indicators, the long s, the thorn.
            ("g\u{131}t", "g" + hex(0x131) + "t"), ("1\u{BA} 2\u{AA}", "1" + hex(0xBA) + " 2" + hex(0xAA)), ("\u{17F}ed", hex(0x17F) + "ed"), ("\u{FE}orn", hex(0xFE) + "orn"),
            // The glue of a name keeps a run whole; a space, a comma, a bracket, an equals sign, a semicolon or a line break ends it.
            ("~/\u{43F}x", "~/" + hex(0x43F) + "x"), ("a_\u{43F}", "a_" + hex(0x43F)), ("a@\u{43F}", "a@" + hex(0x43F)), ("a:\u{43F}", "a:" + hex(0x43F)),
            ("a\\\u{43F}", "a\\" + hex(0x43F)), ("a'\u{43F}", "a'" + hex(0x43F)), ("a\"\u{43F}", "a\"" + hex(0x43F)), ("a.\u{43F}", "a." + hex(0x43F)),
            ("a-\u{43F}", "a-" + hex(0x43F)), ("a/\u{43F}", "a/" + hex(0x43F)), ("a~\u{43F}", "a~" + hex(0x43F)),
            ("a \u{43F}", "a \u{43F}"), ("a,\u{43F}", "a,\u{43F}"), ("a(\u{43F}", "a(\u{43F}"), ("a=\u{43F}", "a=\u{43F}"), ("a;\u{43F}", "a;\u{43F}"), ("a\n\u{43F}", "a\n\u{43F}"),
            // A combining mark belongs to the run and goes with the letter it sits on.
            ("\u{43F}\u{301}x", hex(0x43F, 0x301) + "x"),
            // The run is the input's: a Korean letter between Cyrillic and ASCII ones does not end it.
            ("\u{43F}\u{D55C}x", hex(0x43F) + "\u{D55C}x"),
            // Digits count as much as letters, in either direction.
            ("10-\u{445}", "10-" + hex(0x445)), ("\u{43F}1", hex(0x43F) + "1"),
        ])
    }

    /// With no ASCII letter or digit in the run, the letters are shown.
    @Test func aRunWithoutASCIIShowsItsLetters() {
        checkShown(["curl \u{430}\u{440}\u{440}\u{4CF}\u{435}.\u{441}\u{43E}\u{43C}", "~/\u{455}\u{441}\u{43E}\u{440}\u{435}", "ls -\u{430}", "git push origin \u{441}\u{43E}\u{440}\u{443}",
                    "curl \"\u{430}\u{440}\u{440}\u{4CF}\u{435}\".\u{441}\u{43E}\u{43C}", "\u{430}\u{440}\u{440}\u{4CF}\u{435}\\.\u{441}\u{43E}\u{43C}", "привет мир", "Καλημέρα ο άνθρωπος",
                    "\u{FF52}\u{FF4D}", "echo \u{FF52}\u{FF4D} ok", "echo \u{131}", "А.С. Пушкин", "Α.Ε.", "Он пришёл а она ушла. хор сера как", "\u{43E}\u{440}/\u{43E}\u{440}"])
    }

    @Test func aLatinLetterNoOneMistakesAndTheLigaturesAreShownAmongASCII() {
        // Latin letters ICU does not call look-alikes, the hooked y and the dotless j among them, are of the script of the rest of the run.
        checkShown(["na\u{EF}ve", "caf\u{E9}", "Tiếng Việt Ứng dụng", "Za\u{17C}\u{F3}\u{142}\u{107} g\u{119}\u{15B}l\u{105} ja\u{17A}\u{144}", "\u{1B4}pm \u{237}s", "\u{111}\u{F8}x"])
        // Ligatures of two ASCII letters or more are not look-alikes of one.
        checkShown(["\u{153}uvre", "c\u{153}ur", "\u{E6}ther", "\u{133}s", "\u{1C6}x", "\u{152}uvre"])
    }

    // MARK: A2, punctuation that changes what a command means

    @Test func aDashLookalikeRightBeforeAnASCIILetterOrDigitIsWrittenOut() {
        check([
            ("rm \u{2010}rf /", "rm " + hex(0x2010) + "rf /"), ("rm \u{30FC}rf", "rm " + hex(0x30FC) + "rf"), ("rm \u{2014}rf", "rm " + hex(0x2014) + "rf"),
            ("rm \u{2015}rf", "rm " + hex(0x2015) + "rf"), ("ls \u{3161}la", "ls " + hex(0x3161) + "la"), ("r\u{4E00}f", "r" + hex(0x4E00) + "f"),
            ("ls \u{2212}1", "ls " + hex(0x2212) + "1"), ("x \u{FF70}y", "x " + hex(0xFF70) + "y"), ("ls \u{2013}l", "ls " + hex(0x2013) + "l"),
            // Of two in a row, the one before the letter goes.
            ("git push \u{2011}\u{2011}force", "git push \u{2011}" + hex(0x2011) + "force"), ("echo \u{FF0D}\u{FF0D}x", "echo \u{FF0D}" + hex(0xFF0D) + "x"),
        ])
        // Not before an ASCII letter or digit: shown.
        checkShown(["Python\u{4E00}\u{952E}", "TypeScript\u{30FC}", "\u{6709}\u{4E00}\u{4E2A}bug", "A \u{2014} B", "\u{3161}\u{3161}", "x \u{2212} 1", "ls \u{2010} -l", "foo\u{2010}",
                    "\u{30CE}\u{30FC}\u{30C8}", "\u{30B5}\u{30FC}\u{30D0}\u{30FC}\u{3067}npm", "\u{4E00}\u{4E8C}\u{4E09}", "\u{2014}", "\u{2010}\u{2010}", "\u{4E00}\u{4E2D}"])
    }

    /// The stroke and the prolonged sound mark of CJK text are text after a letter of it; the en dash and the full width tilde are a range between digits.
    @Test func aDashOfCJKTextAfterALetterOfItAndARangeBetweenDigitsAreShown() {
        checkShown(["\u{30E6}\u{30FC}\u{30B6}\u{30FC}ID", "\u{30B5}\u{30FC}\u{30D0}\u{30FC}URL", "\u{7EDF}\u{4E00}API", "\u{552F}\u{4E00}ID", "\u{D55C}\u{3161}ID", "\u{FF76}\u{FF70}x",
                    "\u{30A2}\u{30FC}\u{30C8}2", "echo \u{30E6}\u{30FC}\u{30B6}\u{30FC}ID", "10\u{2013}20", "pages 1\u{2013}9", "1\u{FF5E}3\u{65E5}", "9\u{FF5E}0"])
        check([
            // No letter of CJK text right before it: the start, a space, ASCII, another stroke, a dash of another kind, a digit, a bracket.
            ("\u{30FC}rf", hex(0x30FC) + "rf"), ("ls \u{3161}la", "ls " + hex(0x3161) + "la"), ("rm \u{2010}rf", "rm " + hex(0x2010) + "rf"), ("r\u{4E00}f", "r" + hex(0x4E00) + "f"),
            ("1\u{4E00}x", "1" + hex(0x4E00) + "x"), ("\u{30E6}\u{30FC}\u{30FC}rf", "\u{30E6}\u{30FC}" + hex(0x30FC) + "rf"), ("\u{4E00}\u{4E00}x", "\u{4E00}" + hex(0x4E00) + "x"),
            ("\u{FF08}\u{30FC}x", "\u{FF08}" + hex(0x30FC) + "x"), ("\u{3002}\u{4E00}x", "\u{3002}" + hex(0x4E00) + "x"),
            // Other dashes after CJK text, and the en dash and the tilde where a digit is missing on a side.
            ("\u{30E6}\u{2014}ID", "\u{30E6}" + hex(0x2014) + "ID"), ("\u{30E6}\u{2013}ID", "\u{30E6}" + hex(0x2013) + "ID"), ("a\u{2013}1", "a" + hex(0x2013) + "1"),
            ("1\u{2013}a", "1" + hex(0x2013) + "a"), ("ls \u{2013}l", "ls " + hex(0x2013) + "l"), ("1\u{2014}2", "1" + hex(0x2014) + "2"), ("1\u{2212}2", "1" + hex(0x2212) + "2"),
            ("a\u{FF5E}1", "a" + hex(0xFF5E) + "1"), ("1\u{FF5E}a", "1" + hex(0xFF5E) + "a"), ("\u{FF5E}/x", hex(0xFF5E) + "/x"),
        ])
    }

    /// The multiplication sign is text beside digits and in prose, and a letter of a name between two ASCII letters.
    @Test func theMultiplicationSignBetweenTwoASCIILettersIsWrittenOut() {
        check([("e\u{D7}ample.com", "e" + hex(0xD7) + "ample.com"), ("https://e\u{D7}ample.com", "https://e" + hex(0xD7) + "ample.com"), ("a\u{D7}b", "a" + hex(0xD7) + "b")])
        checkShown(["3\u{D7}4", "3.5\u{D7}2", "a \u{D7} b", "a\u{D7}", "\u{D7}b", "a\u{D7}1", "1\u{D7}b", "\u{D7}", "\u{C5}\u{D7}b", "\u{7F16}\u{D7}b", "4K \u{D7} 3"])
    }

    @Test func aDotColonOrAtLookalikeBetweenTwoLettersOrDigitsIsWrittenOut() {
        check([
            ("https://github.com\u{3002}evil.com/x.sh", "https://github.com" + hex(0x3002) + "evil.com/x.sh"),
            ("a\u{FF61}b", "a" + hex(0xFF61) + "b"), ("a\u{FF0E}b", "a" + hex(0xFF0E) + "b"), ("a\u{FF1A}b", "a" + hex(0xFF1A) + "b"), ("a\u{FF20}b", "a" + hex(0xFF20) + "b"),
            ("1\u{3002}2", "1" + hex(0x3002) + "2"), ("a\u{2024}b", "a" + hex(0x2024) + "b"),
            // Between letters of Cyrillic, Greek and Latin as well: the neighbours need not be ASCII, only letters or digits of those scripts.
            ("\u{430}\u{3002}\u{431}", "\u{430}" + hex(0x3002) + "\u{431}"), ("\u{3B1}\u{3002}\u{3B2}", "\u{3B1}" + hex(0x3002) + "\u{3B2}"), ("\u{E9}\u{3002}a", "\u{E9}" + hex(0x3002) + "a"),
            ("a\u{3002}\u{43F}", "a" + hex(0x3002) + "\u{43F}"),
        ])
        checkShown(["Python\u{3002}", "\u{3067}\u{3059}\u{3002}", "\u{3002}abc", "a \u{3002} b", "a\u{3002}\u{3002}b", "\u{3067}\u{3059}\u{3002}abc", "\u{D55C}\u{AE00}\u{3002}a",
                    "AI\u{B7}\u{BC18}\u{B3C4}\u{CCB4} iOS\u{B7}Android", "a\u{B7}b", "\u{6709}\u{FF1A}a", "\u{6CE8}\u{610F}\u{FF1A}abc"])
    }

    @Test func aSlashBarOrShellOperatorLookalikeBesideASCIIIsWrittenOut() {
        check([
            ("ls \u{FF0F}tmp", "ls " + hex(0xFF0F) + "tmp"), ("a\u{FF0F}b", "a" + hex(0xFF0F) + "b"), ("ls \u{D55C}\u{AE00}/\u{30CE}\u{30FC}\u{30C8}", "ls \u{D55C}\u{AE00}/" + hex(0x30CE) + "\u{30FC}\u{30C8}"),
            ("a\u{FF3C}b", "a" + hex(0xFF3C) + "b"), ("a\u{FF5C}b", "a" + hex(0xFF5C) + "b"), ("a\u{4E28}b", "a" + hex(0x4E28) + "b"), ("a\u{3163}b", "a" + hex(0x3163) + "b"),
            ("x\u{FF06}\u{FF06}y", "x" + hex(0xFF06, 0xFF06) + "y"), ("a\u{FF1B}b", "a" + hex(0xFF1B) + "b"), ("a\u{FF04}HOME", "a" + hex(0xFF04) + "HOME"),
            ("a\u{FF1C}b", "a" + hex(0xFF1C) + "b"), ("a\u{FF1E}b", "a" + hex(0xFF1E) + "b"), ("a\u{FF1D}b", "a" + hex(0xFF1D) + "b"), ("\u{FF0A}.txt", hex(0xFF0A) + ".txt"),
            ("a\u{FF1F}", "a" + hex(0xFF1F)), ("a\u{FF03}", "a" + hex(0xFF03)), ("a\u{FF5E}b", "a" + hex(0xFF5E) + "b"), ("\u{FF04}(id)", hex(0xFF04) + "(id)"),
            ("echo\u{30CE}x", "echo" + hex(0x30CE) + "x"), ("\u{2039}a\u{203A}", hex(0x2039) + "a" + hex(0x203A)), ("a&\u{FF06}", "a&" + hex(0xFF06)),
        ])
        checkShown(["x \u{FF0F} y", "\u{30CE}\u{30FC}\u{30C8}", "\u{FF0F}", "\u{6709}\u{FF06}\u{6CA1}", "x \u{FF5C} y", "\u{4E28}", "\u{3163}\u{3163}", "a \u{FF1D} b", "\u{65E5}\u{FF5E}\u{672C}", "\u{FF0F}\u{FF0F}"])
    }

    @Test func theAngleBracketsThatMarkAnEscapeAreWrittenOutBesideASCIILetters() {
        check([
            ("\u{3008}U+202E\u{3009}", hex(0x3008) + "U+202E" + hex(0x3009)), ("\u{27E8}U+202E\u{27E9}", hex(0x27E8) + "U+202E" + hex(0x27E9)),
            ("\u{3008}7", hex(0x3008) + "7"), ("7\u{3009}", "7" + hex(0x3009)),
        ])
        checkShown(["\u{3008}\u{6587}\u{3009}", "\u{3008}", "\u{3009}", "a\u{3008}", "\u{3009}a", "\u{3008}\u{3009}"])
    }

    /// The rest of what ICU calls a look-alike is shown: the quotes, the ellipsis, the superscripts, the trademark sign, the full width brackets and commas, the crosses.
    @Test func everythingElseICUCallsALookalikeIsShown() {
        checkShown(["\u{201C}hello\u{201D}", "Don\u{2019}t", "Loading\u{2026}", "m\u{B2} n\u{B3} \u{2122}", "\u{FF08}a\u{FF09}", "a\u{FF0C}b", "a\u{FF01}", "x \u{2715} y", "a\u{2715}b",
                    "\u{4F7F}\u{7528}\u{FF08}API\u{FF09}\u{63A5}\u{53E3}", "\u{6709}\u{4E00}\u{4E2A}bug\u{FF0C}\u{8BF7}\u{68C0}\u{67E5}", "a\u{2795}b", "3\u{2795}4", "\u{2022}a", "a\u{2018}b"])
    }

    /// Prose of the languages the app is localized into, as the card shows it: nothing written out.
    @Test func ordinaryProseIsShownAsItIs() {
        checkShown(["C\u{2019}est l\u{2019}\u{E9}t\u{E9}, \u{153}uvre, m\u{B2} \u{E7}a marche\u{2026}", "Don\u{2019}t", "Loading\u{2026}", "\u{201C}hello\u{201D}", "\u{6709}\u{4E00}\u{4E2A}bug\u{FF0C}\u{8BF7}\u{68C0}\u{67E5}",
                    "\u{4F7F}\u{7528}\u{FF08}API\u{FF09}\u{63A5}\u{53E3}", "Python\u{3002}", "Python\u{4E00}\u{952E}\u{5B89}\u{88C5}", "TypeScript\u{30FC}", "AI\u{B7}\u{BC18}\u{B3C4}\u{CCB4} iOS\u{B7}Android",
                    "\u{410}.\u{421}. \u{41F}\u{443}\u{448}\u{43A}\u{438}\u{43D}", "\u{391}.\u{395}.", "Tiếng Việt", "サーバーでnpmを実行（テスト）", "请运行npm install命令，然后一次性完成。",
                    "echo 안녕 && ls 한글 ノート", "echo 😀 ❤️‍🔥 👍🏽"])
    }

    // MARK: Every scalar, against ICU asked in the test

    private func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private func isFullWidthLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0xFF21...0xFF3A).contains(scalar.value) || (0xFF41...0xFF5A).contains(scalar.value)
    }

    private func isFullWidthDigit(_ scalar: Unicode.Scalar) -> Bool { (0xFF10...0xFF19).contains(scalar.value) }

    /// What the rules say of a scalar that `escape` shows by itself, worked out here from ICU's skeleton, compatibility form and script and the lead's list.
    /// The full width digits are judged by their run, so they are plain here; the signs of ordinary text whose form is an ASCII letter or digit are plain too.
    private enum Kind: Equatable { case foreignLetter, standsFor(Character), plain }

    private func kind(of scalar: Unicode.Scalar, lookalike: (Unicode.Scalar) -> String?, script: (Unicode.Scalar) -> String) -> Kind {
        let extras: [UInt32: Character] = [0x3161: "-", 0x4E00: "-", 0x30FC: "-", 0xFF70: "-", 0x2014: "-", 0x2015: "-", 0x3163: "|", 0x4E28: "|", 0x3021: "|", 0x2758: "|",
                                           0x3002: ".", 0xFF61: "."]
        let name = script(scalar), form = lookalike(scalar)
        if isFullWidthDigit(scalar) { return .plain }
        if isLetterOrDigit(scalar) {
            if isFullWidthLetter(scalar) || ((name == "Cyrillic" || name == "Greek") && scalar.properties.generalCategory != .otherNumber) { return .foreignLetter }
            if name == "Latin", let form, !form.hasPrefix("no skeleton") {
                return form.unicodeScalars.filter { $0.properties.isAlphabetic && $0.value < 0x80 }.count >= 2 ? .plain : .foreignLetter
            }
            if name == "Latin", form != nil { return .foreignLetter }
        }
        // Of any script or category: a form of one ASCII letter or digit, but for the signs of ordinary text.
        if let form, form.count == 1, form.first!.isASCII, form.first!.isLetter || form.first!.isNumber, ![0xD7, 0xB2, 0xB3, 0xB9].contains(scalar.value) { return .foreignLetter }
        if let extra = extras[scalar.value] { return .standsFor(extra) }
        if scalar.value == 0x3008 || scalar.value == 0x3009 { return .plain }
        if let form, form.count == 1, "-/\\.:@~|;&$<>=*?#".contains(form.first!) { return .standsFor(form.first!) }
        return .plain
    }

    /// For every scalar `escape` shows by itself: a Cyrillic or Greek letter, a full width Latin letter or digit or a Latin letter that ICU takes for an ASCII
    /// one is written out beside an ASCII letter and gives the chip alone, and nothing else gives the chip.
    /// What a sweep over the scalars found: the expectations that failed, and how many scalars of each kind it met.
    private struct Sweep: Sendable {
        var failures: [String] = []
        var count = 0
        var byScript: [String: Int] = [:]
        var classes: [Character: Int] = [:]
    }

    @Test func everyForeignLetterIsWrittenOutBesideASCIIAndGivesTheChipAlone() async throws {
        let (lookalike, script) = (try asciiLookalikes(), try scriptNames())
        let shownScalars = await ShownScalars.pastASCII()
        // On a thread of its own (see `offPool`), which reports what failed and leaves the expectations to this task.
        let sweep = await offPool { [self] in
            var sweep = Sweep()
            func expect(_ holds: Bool, _ message: @autoclosure () -> String) { if !holds { sweep.failures.append(message()) } }
            for scalar in shownScalars {
                let value = scalar.value, text = String(scalar), label = "U+" + String(value, radix: 16, uppercase: true)
                let isForeign = kind(of: scalar, lookalike: lookalike, script: script) == .foreignLetter
                if isForeign {
                    sweep.count += 1
                    sweep.byScript[script(scalar), default: 0] += 1
                    for around in ["a" + text, text + "a", "a" + text + "b", "7" + text, "~/" + text + "x", "x." + text] {
                        let expected = around.unicodeScalars.map { $0 == scalar ? hex(value) : String($0) }.joined()
                        expect(escaped(around) == expected, "\(label) in \(around)")
                    }
                    // With no ASCII letter or digit in the run, it is shown.
                    for around in [text, text + text, " " + text + " ", "~/" + text, "-" + text, "\"" + text + "\".", "\u{43E}" + text, "\u{AC00}" + text] {
                        expect(escaped(around) == around, "\(label) in \(around)")
                    }
                }
            }
            return sweep
        }
        #expect(sweep.failures.isEmpty, "\(sweep.failures.count): \(sweep.failures.prefix(12))")
        let (foreign, byScript) = (sweep.count, sweep.byScript)
        #expect(foreign > 400 && byScript["Cyrillic", default: 0] > 200 && byScript["Greek", default: 0] > 100 && byScript["Latin", default: 0] > 50
                && byScript["Common", default: 0] >= 25, "\(foreign) \(byScript)")
    }

    /// For every scalar `escape` shows by itself that stands for one of `- / \\ . : @ ~ | ; & $ < > = * ? #`: the rule of its class, in every neighbourhood.
    @Test func everyPunctuationLookalikeFollowsTheRuleOfItsClass() async throws {
        let (lookalike, script) = (try asciiLookalikes(), try scriptNames())
        let shownScalars = await ShownScalars.pastASCII()
        // On a thread of its own (see `offPool`), which reports what failed and leaves the expectations to this task.
        let sweep = await offPool { [self] in
            var sweep = Sweep()
            func expect(_ holds: Bool, _ message: @autoclosure () -> String) { if !holds { sweep.failures.append(message()) } }
            for scalar in shownScalars {
                let value = scalar.value
                guard case .standsFor(let ascii) = kind(of: scalar, lookalike: lookalike, script: script) else { continue }
                let text = String(scalar), written = hex(value), label = "U+" + String(value, radix: 16, uppercase: true)
                sweep.classes[ascii, default: 0] += 1
                // Every class is shown with spaces, a Korean letter or a CJK one about it, and alone.
                for around in [" " + text + " ", "\u{D55C}" + text + "\u{AE00}", "\u{4E2D}" + text + "\u{6587}", text + text, text + "\u{D55C}", "\u{D55C}" + text] {
                    expect(escaped(around) == around, "\(label) in \(around)")
                }
                switch ascii {
                case "-":
                    // Written out right before an ASCII letter or digit, and nowhere else.
                    for after in ["a", "Z", "0", "9"] { expect(escaped(text + after) == written + after && escaped("x" + text + after) == "x" + written + after, "\(label) \(after)") }
                    for around in ["a" + text, "a" + text + " ", "a" + text + "\u{D55C}", "a" + text + ".", "a" + text + "-", "9" + text + "_"] { expect(escaped(around) == around, "\(label) in \(around)") }
                case ".", ":", "@":
                    // Written out between two letters or digits of ASCII, Latin, Cyrillic or Greek.
                    for (before, after) in [("a", "b"), ("1", "2"), ("a", "9"), ("\u{E9}", "x"), ("\u{430}", "\u{431}"), ("\u{3B1}", "\u{3B2}"), ("x", "\u{43F}")] {
                        expect(escaped(before + text + after) == before + written + after, "\(label) \(before)\(after)")
                    }
                    for around in ["a" + text, text + "a", "a" + text + ".", "a" + text + " b", "a" + text + "\u{D55C}", "\u{D55C}" + text + "a", "a" + text + "\u{4E2D}", "a" + text + "-b", "a-" + text + "b"] {
                        expect(escaped(around) == around, "\(label) in \(around)")
                    }
                default:
                    // Written out beside an ASCII letter, digit or punctuation mark on either side.
                    for other in ["a", "9", ".", "/", "-", "(", "\"", "~", "$"] {
                        expect(escaped(text + other) == written + other && escaped(other + text) == other + written && escaped(" " + text + other) == " " + written + other, "\(label) \(other)")
                    }
                    for around in [text + " ", " " + text, text + "\u{D55C}", "\u{D55C}" + text, text + "\u{4E2D}", "\u{D55C}" + text + "\u{4E2D}"] { expect(escaped(around) == around, "\(label) in \(around)") }
                }
            }
            return sweep
        }
        #expect(sweep.failures.isEmpty, "\(sweep.failures.count): \(sweep.failures.prefix(12))")
        let classes = sweep.classes
        #expect(classes["-", default: 0] >= 8 && classes["."] != nil && classes[":"] != nil && classes["@"] != nil && classes["/"] != nil && classes["\\"] != nil && classes["|"] != nil
                && classes["&"] != nil && classes["$"] != nil && classes["="] != nil && classes["<"] != nil && classes[">"] != nil && classes["*"] != nil && classes["?"] != nil
                && classes["#"] != nil && classes[";"] != nil && classes["~"] != nil, "\(classes)")
    }

    /// Ordinary text the certain cases write out anyway, pinned so a change to the rules shows. Each is a consequence of a rule, not a goal: a Latin letter ICU
    /// takes for an ASCII one among ASCII letters, a Cyrillic letter after a digit and a hyphen, a dash between ASCII letters, a katakana that
    /// reads as a slash after a slash.
    @Test func theOrdinaryTextTheRulesDoWriteOutIsPinned() {
        check([
            ("k\u{131}sa", "k" + hex(0x131) + "sa"), ("1\u{BA} piso, N\u{BA} 5, 2\u{AA}", "1" + hex(0xBA) + " piso, N" + hex(0xBA) + " 5, 2" + hex(0xAA)), ("\u{FE}etta", hex(0xFE) + "etta"),
            ("end\u{2014}start", "end" + hex(0x2014) + "start"), ("10-\u{445}", "10-" + hex(0x445)),
            ("~/\u{30CE}\u{30FC}\u{30C8}", "~/" + hex(0x30CE) + "\u{30FC}\u{30C8}"),
            // A letter of no script the rules judge that ICU takes for an ASCII one is written out all the same; apart, it is shown.
            ("\u{2113}s", hex(0x2113) + "s"), ("x \u{211D}", "x \u{211D}"),
        ])
    }

    // MARK: Fail closed

    /// Without ICU every scalar past ASCII is written out, whatever it is made of.
    @Test func withoutICUEveryScalarPastASCIIIsWrittenOut() {
        let samples = ["\u{1F1F0}\u{1F1F7}", "\u{1F600}", "\u{2764}\u{FE0F}", "\u{2764}\u{FE0E}", "1\u{FE0F}\u{20E3}", "#\u{FE0F}\u{20E3}", "\u{1F44D}\u{1F3FD}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
                       "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "\u{D55C}\u{AE00}", "\u{65E5}\u{672C}", "\u{30CE}\u{30FC}\u{30C8}", "\u{43F}pm", "\u{FF52}m", "\u{E9}t\u{E9}", "\u{153}uvre", "\u{2019}", "\u{2026}",
                       "x\u{323}", "\u{200D}", "\u{3002}", "\u{3008}\u{3009}", "\u{20E3}", "\u{1F3FD}", "\u{FE0F}", "\u{300}"]
        for sample in samples {
            for text in [sample, "ls " + sample + " ok", "a" + sample] {
                let expected = String(String.UnicodeScalarView(text.precomposedStringWithCanonicalMapping.unicodeScalars.flatMap { scalar -> [Unicode.Scalar] in
                    scalar.value < 0x80 ? [scalar] : Array(hex(scalar.value).unicodeScalars)
                }))
                #expect(PermissionText.escape(text, multiline: true, failClosed: true) == expected, "\(name(text))")
            }
        }
        // ASCII, the tab and the line break are as before.
        #expect(PermissionText.escape("a\tb\r\nc", multiline: true, failClosed: true) == "a\u{21E5} b\nc")
        #expect(PermissionText.escape("a\nb", multiline: false, failClosed: true) == "a" + hex(0xA) + "b")
        // With ICU the same samples are not all written out.
        #expect(escaped("\u{1F600}") == "\u{1F600}" && escaped("\u{D55C}\u{AE00}") == "\u{D55C}\u{AE00}")
    }

    /// Every scalar of Unicode, alone and after what could carry it along (a letter, a picture that takes a tone or a selector, a digit for a keycap, a regional
    /// indicator, a joiner): nothing past ASCII is left in what comes out but the brackets of an escape and the tab's arrow.
    @Test func withoutICUNothingPastASCIIIsLeftInWhatComesOut() async {
        let contexts = ["", "a", "\u{1F44D}", "\u{2764}", "1\u{FE0F}", "\u{1F1E6}", "\u{1F600}\u{200D}"]
        let allowed: Set<UInt32> = [0x27E8, 0x27E9, 0x21E5]
        // On a thread of its own (see `offPool`): the first scalar left in is reported, and the sweep stops there.
        let (checked, leak) = await offPool { [self] () -> (Int, String?) in
            var checked = 0
            for value in UInt32(0x80)...0x10FFFF {
                guard let scalar = Unicode.Scalar(value), scalar.properties.generalCategory != .unassigned, scalar.properties.generalCategory != .privateUse else { continue }
                for context in contexts {
                    for text in [context + String(scalar) + "\u{20E3}\u{1F600}"] {
                        let out = PermissionText.escape(text, multiline: true, failClosed: true)
                        if let leaked = out.unicodeScalars.first(where: { $0.value > 0x7F && !allowed.contains($0.value) }) {
                            return (checked, "U+\(String(leaked.value, radix: 16, uppercase: true)) is left in \(name(text))")
                        }
                        checked += 1
                    }
                }
            }
            return (checked, nil)
        }
        if let leak { Issue.record(Comment(rawValue: leak)); return }
        #expect(checked > 500_000, "\(checked)")
    }

    // MARK: Look-alikes of letters that are no letters of Latin, Greek or Cyrillic

    @Test func aLookalikeOfALetterIsWrittenOutInARunWithASCII() {
        let cases: [(String, String)] = [
            ("ℓs -la", hex(0x2113) + "s -la"), ("ℯcho hi", hex(0x212F) + "cho hi"), ("node -e \"ℯval('x')\"", "node -e \"" + hex(0x212F) + "val('x')\""),
            ("ls ∣s", "ls " + hex(0x2223) + "s"), ("a∨b", "a" + hex(0x2228) + "b"), ("x╳y", "x" + hex(0x2573) + "y"), ("a⊤b", "a" + hex(0x22A4) + "b"),
            ("a\u{2229}b ℝ", "a\u{2229}b ℝ"), ("cat ./〇a", "cat ./" + hex(0x3007) + "a"), ("ℂ1", hex(0x2102) + "1"), ("ρℓ", "\u{3C1}ℓ"),
        ]
        for (text, expected) in cases { #expect(escaped(text) == expected, "\(name(text))") }
    }

    /// Every one of the lead's list is a look-alike: written out beside ASCII, shown apart from it.
    @Test func theLetterlikeAndMathScalarsAreWrittenOutBesideASCII() {
        for scalar in "ℓℯℊℎℐℑℒℂℍℝℕℙℚℤⅇⅈⅉ∣∨⋁∪⋃⊤⋿╳〇".unicodeScalars {
            let text = String(scalar)
            #expect(escaped("a" + text + "b") == "a" + hex(scalar.value) + "b" && escaped(text + "a") == hex(scalar.value) + "a", "\(name(text))")
            #expect(escaped(text) == text && escaped("x " + text) == "x " + text, "\(name(text))")
        }
    }

    /// Signs whose form is a letter or digit but that are ordinary text: the superscripts of units and notes, and what is two letters, the trademark and
    /// service mark signs and the infinity sign. (The multiplication sign is written out only between two ASCII letters, in its own test.)
    @Test func theSignsOfOrdinaryTextAreShownBesideASCII() {
        for text in ["²", "³", "¹", "™", "℠", "∞", "№", "‖", "∥", "₨", "½"] { #expect(escaped("a" + text + "b") == "a" + text + "b", "\(name(text))") }
        checkShown(["echo 3\u{D7}4 m² cm³ note¹ Acme™ x∞", "echo \"Acme™ 12.5m² 3.5\u{D7}2\""])
    }

    @Test func hanZeroIsALookalikeExceptBesideAnIdeograph() {
        checkShown(["二〇二四年", "2024年二〇二四年", "〇〇", "〇一", "平成〇年", "ls 二〇", "echo 二〇二四年", "echo 2024年二〇二四年"])
        #expect(escaped("a〇") == "a" + hex(0x3007) && escaped("a〇二") == "a〇二" && escaped("〇b") == hex(0x3007) + "b")
    }

    // MARK: Full width digits

    @Test func aFullWidthDigitIsWrittenOutOnlyBesideAnASCIILetter() {
        let (digit, wide) = ("\u{FF11}", hex(0xFF11))
        // Shown where the run holds no ASCII letter.
        checkShown(["第" + digit + "回の資料を ls する", "（" + digit + "）", digit, digit + "5", "5" + digit, "1" + digit + "3", "~/" + digit, "第" + digit + "回2024", "x " + digit + " y",
                    "第１回の資料を ls する", "echo １２３ 4５6", "ls ~/第１回.5"])
        // Written out beside one.
        for (text, expected) in [("file" + digit, "file" + wide), (digit + "a", wide + "a"), ("a" + digit + "5", "a" + wide + "5"), ("第" + digit + "回.txt", "第" + wide + "回.txt"),
                                 ("~/" + digit + "x", "~/" + wide + "x"), ("x." + digit, "x." + wide)] {
            #expect(escaped(text) == expected, "\(name(text))")
        }
        // Full width letters keep to the rule of letters: written out in a run with ASCII, shown apart from it.
        #expect(escaped("ｒm") == hex(0xFF52) + "m" && escaped("ｒｍ") == "ｒｍ" && escaped("ＡＢＣ商事の請求書.pdf") == hex(0xFF21, 0xFF22, 0xFF23) + "商事の請求書.pdf")
    }

    // MARK: Always allow

    private func suggestion(_ rules: [[String: Any]]) -> [String: Any] { ["type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": rules] }

    @Test func aRuleIsOfferedOnlyWhenEveryScalarOfItIsPrintableASCII() throws {
        func rule(_ content: String) -> [String: Any] { ["toolName": "Bash", "ruleContent": content] }
        #expect(PermissionPrompt.grant(from: suggestion([rule("npm test:*")]))?.rules == ["Bash(npm test:*)"])
        #expect(PermissionPrompt.grant(from: suggestion([["toolName": "WebFetch"], ["toolName": "Read", "ruleContent": "/a/**"]]))?.rules == ["WebFetch", "Read(/a/**)"])
        for content in ["curl \u{430}\u{440}\u{440}\u{4CF}\u{435}.\u{441}\u{43E}\u{43C}:*", "echo \u{C548}\u{B155}:*", "echo \u{30CE}\u{30FC}\u{30C8}:*", "echo r\u{E9}sum\u{E9}:*", "echo \u{2026}:*",
                        "echo a\tb:*", "echo a\nb:*", "echo a\u{7F}b:*", "echo a\u{0}b:*", "echo \u{1F600}:*", "echo \u{FF52}:*", "ls \u{2010}la:*", "echo \u{A0}:*", "echo \u{200B}:*"] {
            #expect(PermissionPrompt.grant(from: suggestion([rule(content)])) == nil, "\(name(content))")
            #expect(PermissionPrompt.grant(from: suggestion([rule("npm test:*"), rule(content)])) == nil, "\(name(content))")
        }
        // In the name of a tool as well.
        for tool in ["mcp__\u{D55C}\u{AE00}", "mcp__\u{43F}", "mcp__\u{30CE}", "mcp__a\u{E9}"] {
            #expect(PermissionPrompt.grant(from: suggestion([["toolName": tool, "ruleContent": "x"]])) == nil, "\(name(tool))")
            #expect(PermissionPrompt.grant(from: suggestion([["toolName": tool]])) == nil, "\(name(tool))")
        }
        // Through the parser: the prompt has no rule and the answer has no suggestion to echo.
        for content in ["curl \u{430}\u{440}\u{440}\u{4CF}\u{435}.\u{441}\u{43E}\u{43C}:*", "echo \u{C548}\u{B155}:*", "echo \u{30CE}\u{30FC}\u{30C8}:*"] {
            let body = PermissionTestServer.hookInput(suggestions: [suggestion([rule(content)])])
            let parsed = try #require(PermissionPrompt.parse(body))
            #expect(parsed.prompt.grant == nil && parsed.suggestion == nil, "\(name(content))")
        }
        let fine = PermissionTestServer.hookInput(suggestions: [suggestion([rule("npm test:*")])])
        let parsed = try #require(PermissionPrompt.parse(fine))
        #expect(parsed.prompt.grant?.rules == ["Bash(npm test:*)"] && parsed.suggestion != nil)
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

    /// A joiner is kept only before a picture that is shown: a picture that stands for a dash, right before an ASCII letter, is written out, and the joiner with it.
    @Test func aJoinerBeforeAPictureThatIsWrittenOutIsWrittenOutToo() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(drawing(family).count == 1)
        #expect(escaped(family + "\u{200D}\u{2796}x") == family + hex(0x200D, 0x2796) + "x")
        #expect(escaped(family) == family && escaped("a" + family) == "a" + family)
        // Where the picture is shown, the whole is no picture of the font's: every joiner goes.
        #expect(escaped(family + "\u{200D}\u{2796}") == "\u{1F468}" + hex(0x200D) + "\u{1F469}" + hex(0x200D) + "\u{1F467}" + hex(0x200D) + "\u{2796}")
    }

    @Test func aKeycapKeepsItsSelectorAndNothingElseDoes() {
        for digit in ["0", "1", "5", "9", "#", "*"] { #expect(escaped(digit + "\u{FE0F}\u{20E3}") == digit + "\u{FE0F}\u{20E3}", "\(digit)") }
        #expect(escaped("1\u{FE0F}") == "1" + hex(0xFE0F) && escaped("a\u{FE0F}\u{20E3}") == "a" + hex(0xFE0F, 0x20E3))
    }
}
