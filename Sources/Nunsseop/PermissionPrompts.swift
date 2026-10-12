import AppKit
import CryptoKit
import Foundation
import os

/// How a permission prompt in the notch was answered.
enum PermissionAnswer: Equatable {
    case allow, deny, always
}

/// The messages between Claude Code's PermissionRequest hook and the server. The token never travels: each side proves
/// it knows it with an HMAC-SHA256 keyed by the token, over a domain, the request's nonce and a SHA-256 of what is
/// vouched for, so neither a request nor an answer can be forged or moved to another request.
enum PermissionWire {
    static let requestDomain = "nunsseop-permission-request"
    static let responseDomain = "nunsseop-permission-response"

    /// 16 random bytes as lowercase hex.
    static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func mac(token: String, domain: String, nonce: String, payload: Data) -> String {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let message = Data("\(domain)\n\(nonce)\n\(digest)".utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Sent as `X-Proof`, with the nonce as `X-Nonce`; the payload is the request body.
    static func requestProof(token: String, nonce: String, body: Data) -> String {
        mac(token: token, domain: requestDomain, nonce: nonce, payload: body)
    }

    /// The answer's body is this, a space, and the decision the hook prints.
    static func responseProof(token: String, nonce: String, decision: Data) -> String {
        mac(token: token, domain: responseDomain, nonce: nonce, payload: decision)
    }

    static let denyMessage = "Denied in Nunsseop"

    /// What Claude Code reads from the hook's stdout. `always` echoes the one suggestion the prompt offered.
    static func decision(_ answer: PermissionAnswer, suggestion: [String: Any]?) -> Data? {
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny", "message": denyMessage]
        case .always:
            guard let suggestion else { return nil }
            decision = ["behavior": "allow", "updatedPermissions": [suggestion]]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// What a prompt shows is what the tool would do, so nothing is dropped or joined, nothing invisible is left invisible, and
/// nothing is drawn that the card can't lay out inside its row. Only what is listed here is shown; every other scalar is
/// written out.
enum PermissionText {
    /// Shown as they are, besides ASCII and the space: Latin-1, Latin Extended-A, -B and Additional, Greek, Cyrillic, general
    /// punctuation (not the separators, the joiners or the marks of direction), currency, letterlike symbols, arrows, math
    /// operators, a few keys of Miscellaneous Technical, box drawing, geometric shapes, a few stars, dingbats, CJK signs, kana,
    /// Hangul compatibility letters, CJK ideographs, Hangul syllables, and full and half width forms. Only letters, numbers,
    /// punctuation and symbols of them count: no mark, no space, no unassigned scalar. Those that read as ASCII only where
    /// the run they stand in lets them.
    private static let shown: [ClosedRange<UInt32>] = [
        0xA1...0xFF, 0x100...0x24F, 0x1E00...0x1EFF, 0x370...0x3FF, 0x400...0x4FF, 0x2010...0x2027, 0x2030...0x205E,
        0x20A0...0x20C0, 0x2100...0x214F, 0x2190...0x21FF, 0x2200...0x22FF, 0x2303...0x2303, 0x2318...0x2318, 0x2325...0x2325,
        0x23CE...0x23CE, 0x2500...0x257F, 0x25A0...0x25FF, 0x2605...0x2606, 0x2700...0x27BF, 0x3001...0x303F, 0x3041...0x309F,
        0x30A0...0x30FF, 0x3131...0x318E, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xFF01...0xFF5E, 0xFF61...0xFF9D]
    /// Scalars of those ranges that are written out nonetheless: the soft hyphen, the Hangul filler, the arrow that stands
    /// for a tab, and what drew outside its row, or more than a point past either side of its cell by its outline or by the
    /// pixels it paints, or nothing, or a fallback box, when every scalar was laid out in the card's fonts: Latin and Greek
    /// letters whose accents or hooks reach past the row or more than a point past the cell, the box-drawing pieces that run
    /// past the row, the radicals and slashes that run wide, the signs no font has, and a few more.
    private static let withheld: [ClosedRange<UInt32>] = [
        0xAD...0xAD, 0x187...0x187, 0x193...0x193, 0x1D7...0x1D7, 0x1D9...0x1D9, 0x1DB...0x1DB, 0x1FA...0x1FA, 0x208...0x209, 0x37A...0x37A,
        0x390...0x390, 0x3D3...0x3D3, 0x47C...0x47C, 0x1E00...0x1E01, 0x1E14...0x1E14, 0x1E16...0x1E16, 0x1E2E...0x1E2E,
        0x1E4C...0x1E4C, 0x1E4E...0x1E4E, 0x1E50...0x1E50, 0x1E52...0x1E52, 0x1E66...0x1E66, 0x1E78...0x1E78, 0x1E7A...0x1E7A,
        0x1E9C...0x1E9D, 0x1EA4...0x1EA4, 0x1EA6...0x1EA6, 0x1EA8...0x1EA8, 0x1EAA...0x1EAA, 0x1EAE...0x1EAE, 0x1EB0...0x1EB0,
        0x1EB2...0x1EB2, 0x1EB4...0x1EB4, 0x1EBE...0x1EBE, 0x1EC0...0x1EC0, 0x1EC2...0x1EC2, 0x1EC4...0x1EC4, 0x1ED0...0x1ED0,
        0x1ED2...0x1ED2, 0x1ED4...0x1ED4, 0x1ED6...0x1ED6, 0x1EFE...0x1EFE, 0x2017...0x2017, 0x2038...0x2038, 0x2044...0x2044, 0x20C0...0x20C0,
        0x21E5...0x21E5, 0x2215...0x2215, 0x221A...0x221B, 0x2502...0x2503, 0x250C...0x2513, 0x251C...0x2533, 0x253C...0x254B,
        0x254E...0x254F, 0x2551...0x2557, 0x255E...0x2566, 0x256A...0x256E, 0x2577...0x2577, 0x257B...0x257B, 0x257D...0x257D,
        0x257F...0x257F, 0x2700...0x2700, 0x275F...0x2760, 0x3164...0x3164]
    /// The letters of ASCII that rise no higher than the middle of the row and sink no lower than its baseline: the only ones
    /// that may carry a combining mark, because a mark on a taller or deeper one reaches into the next row.
    private static let markBases = Set("acemnorsuvwxz".unicodeScalars.map(\.value))
    /// The combining marks that fit above, below or beside those letters in every font the card uses. Not among them: the double
    /// marks of U+035C-0362, which reach over the next letter, the grapheme joiner, which draws nothing, and the marks that
    /// normalization turns into others.
    private static let marks: [ClosedRange<UInt32>] = [
        0x300...0x315, 0x31A...0x31B, 0x320...0x320, 0x323...0x324, 0x327...0x328, 0x32E...0x332, 0x334...0x334,
        0x337...0x338, 0x33C...0x33E, 0x342...0x342, 0x346...0x346, 0x34A...0x34A, 0x350...0x352, 0x357...0x358, 0x363...0x364,
        0x366...0x368, 0x36B...0x36C, 0x36E...0x36F]
    /// The pictures: assigned emoji of the Mahjong tiles to Symbols and Pictographs Extended-A, and of Miscellaneous Symbols
    /// and Dingbats. Text symbols such as ©, ™ and ↔ are not among them, and nothing joins to those.
    private static let pictures: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x1F000...0x1FAFF]
    /// The scalars of `shown`, `pictures` and `marks` that read as ASCII. ICU's spoof checker maps each to its skeleton, the form
    /// two strings share when they can be mistaken for each other: a scalar whose skeleton is ASCII, and so not itself, is one
    /// (the hyphens U+2010 and U+2212, the Greek and Cyrillic letters drawn like Latin ones). The full width forms are too, and so
    /// is anything whose compatibility form is ASCII, which the skeleton doesn't always say. They are judged by the run they
    /// stand in, as a browser judges a host name, and written out when the run can be read as ASCII. Worked out once, on first
    /// use. Nil when the checker can't be loaded: nothing past ASCII is shown then.
    private static let lookalikes: Set<UInt32>? = {
        typealias Open = @convention(c) (UnsafeMutablePointer<Int32>) -> OpaquePointer?
        typealias Close = @convention(c) (OpaquePointer?) -> Void
        typealias Skeleton = @convention(c) (OpaquePointer?, UInt32, UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<UInt8>?, Int32,
                                             UnsafeMutablePointer<Int32>) -> Int32
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW), let open = dlsym(library, "uspoof_open"),
              let close = dlsym(library, "uspoof_close"), let skeleton = dlsym(library, "uspoof_getSkeletonUTF8") else { return nil }
        var status: Int32 = 0
        guard let checker = unsafeBitCast(open, to: Open.self)(&status), status <= 0 else { return nil }
        defer { unsafeBitCast(close, to: Close.self)(checker) }
        let skeletonOf = unsafeBitCast(skeleton, to: Skeleton.self)
        var found = Set<UInt32>()
        var out = [UInt8](repeating: 0, count: 64)
        for value in (shown + pictures + marks).lazy.flatMap({ $0 }) where value >= 0x80 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = Array(String(scalar).utf8)
            status = 0
            let length = skeletonOf(checker, 0, text, Int32(text.count), &out, Int32(out.count), &status)
            let compatible = Array(String(scalar).decomposedStringWithCompatibilityMapping.utf8)
            if status > 0 || (length > 0 && out[0..<Int(length)].allSatisfy { $0 < 0x80 })
                || (!compatible.isEmpty && compatible.allSatisfy { $0 < 0x80 }) { found.insert(value) }
        }
        return found
    }()
    /// Scalars the checker misses that draw like ASCII punctuation: the Korean and CJK strokes and the prolonged sound mark
    /// like a hyphen or a slash, the dashes and the middle dot, the ideographic full stops that IDNA maps to a period, and the
    /// angle brackets that look like the ones round an escape. They count with `lookalikes` wherever a run is judged.
    private static let drawnLikeASCII: Set<UInt32> = [
        0x3161, 0x3163, 0x4E28, 0x4E00, 0x30FC, 0xFF70, 0x3021, 0x2758, 0x2014, 0x2015, 0xB7, 0x3002, 0xFF61, 0x3008, 0x3009]
    /// Whether the zero-width joiners in a sequence of pictures draw it as one picture in the card's font, by sequence. Asked of
    /// CoreText once each; the cache stops growing at a few thousand.
    private static let sequences = OSAllocatedUnfairLock(initialState: [String: Bool]())
    /// Joiners one emoji may hold. A cluster is one unit that can't be broken across rows, so a longer chain could not wrap.
    static let maxJoiners = 4
    /// What a tab is shown as; `⇥` itself is written out, so this can't be faked.
    static let tab = "⇥ "

    /// A scalar whose own normalization form C is another is written out first, so normalizing can never turn what is shown
    /// into something else (the Kelvin sign into K, the Greek question mark into a semicolon, a compatibility ideograph
    /// into its unified one). The rest is put in form C, so a path macOS stored decomposed reads as it was typed.
    /// What is shown is ASCII, the space, and the scalars of `shown`; a tab is shown as `tab`, and a line break stays one
    /// when `multiline`. Anything else is written out as `⟨U+202E⟩`, and so are the angle brackets that mark one, so an
    /// escape can't be faked. A scalar that reads as ASCII, of `lookalikes` or `drawnLikeASCII`, is judged by its run: the
    /// longest stretch of the input made only of ASCII letters and digits, ASCII punctuation, and such scalars. A scalar that
    /// is none of those ends it, and so does a space, a tab, a CR, an LF, a scalar that is written out, and a picture. Every
    /// look-alike of a run is written out when the run has an ASCII letter or digit, or when an ASCII punctuation mark or a
    /// look-alike that is punctuation or a symbol has a look-alike right before it and another right after, as in a host name
    /// or a path made of them. Otherwise they are shown, as in a word of a language of its own. The runs are the input's, not
    /// the escaped text's, which holds the letters and digits of every escape. What emoji are made of stays: the emoji
    /// variation selector right after a picture that it changes (not one drawn in colour already), the text one, and one skin
    /// tone right after a picture that takes it, each only when CoreText draws the picture differently with it; the zero-width
    /// joiners of a sequence of pictures, up to `maxJoiners` in a row, that CoreText draws as one picture, and the colour
    /// selectors in it; regional indicators two by two; the keycap of a digit, `#` or `*`. A combining mark of `marks` stays
    /// when it is the only one on a letter of `markBases`. CR LF counts as one break.
    static func escape(_ text: String, multiline: Bool) -> String {
        var tokens: [Token] = []
        var run = String.UnicodeScalarView()
        func flush() {
            guard !run.isEmpty else { return }
            tokens.append(contentsOf: String(run).precomposedStringWithCanonicalMapping.unicodeScalars.map { Token(scalar: $0, changes: false) })
            run = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x300 || String(scalar).precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual([scalar]) {
                run.append(scalar)
            } else {
                flush()
                tokens.append(Token(scalar: scalar, changes: true))
            }
        }
        flush()
        hideLookalikes(&tokens)

        var result = String.UnicodeScalarView()
        // What was just shown, and what may follow it.
        var previous: Unicode.Scalar?
        var takesMark = false, takesTone = false, selected = false, keycap = false, pairOpen = false
        // The joiners in the picture being shown, nil when what was just shown isn't one; and whether its sequence draws as one.
        var joined: Int?, joins = false
        func reset() {
            previous = nil
            takesMark = false
            takesTone = false
            selected = false
            keycap = false
            pairOpen = false
            joined = nil
        }
        var index = 0
        while index < tokens.count {
            let (scalar, changes, hidden) = (tokens[index].scalar, tokens[index].changes, tokens[index].hidden)
            index += 1
            let next = index < tokens.count && !tokens[index].changes ? tokens[index].scalar : nil
            if scalar == "\r", next == "\n" { continue }
            if scalar == "\n" && multiline {
                result.append(scalar)
                reset()
            } else if scalar == "\t" {
                result.append(contentsOf: tab.unicodeScalars)
                reset()
            } else if changes {
                appendEscape(scalar, to: &result)
                reset()
            } else if scalar.value == 0xFE0E || scalar.value == 0xFE0F, let before = previous, !selected,
                      (isPicture(before) && (keeps(scalar, after: before) || (scalar.value == 0xFE0F && joins && joined != nil && !before.properties.isEmojiPresentation)))
                        || (scalar.value == 0xFE0F && next?.value == 0x20E3 && isKeycapBase(before)) {
                result.append(scalar)
                keycap = !isPicture(before)
                selected = true
                takesMark = false
                takesTone = false
            } else if scalar.value == 0x20E3, keycap, selected {
                result.append(scalar)
                reset()
                previous = scalar
            } else if scalar.value == 0x200D, joins, let count = joined, count < maxJoiners, let after = next, isPicture(after), !tokens[index].hidden {
                result.append(scalar)
                joined = count + 1
                previous = scalar
                takesMark = false
                takesTone = false
                selected = false
            } else if (0x1F3FB...0x1F3FF).contains(scalar.value), takesTone, let before = previous, keeps(scalar, after: before) {
                result.append(scalar)
                previous = scalar
                takesTone = false
                selected = false
            } else if isRegional(scalar), pairOpen || next.map(isRegional) == true {
                result.append(scalar)
                let opened = !pairOpen
                reset()
                previous = scalar
                pairOpen = opened
            } else if takesMark, marks.contains(where: { $0.contains(scalar.value) }) {
                result.append(scalar)
                reset()
                previous = scalar
            } else if isPicture(scalar), !hidden {
                result.append(scalar)
                let afterJoiner = previous?.value == 0x200D
                let count = joined
                reset()
                previous = scalar
                joined = afterJoiner ? count : 0
                if !afterJoiner {
                    let candidate = chain(tokens, from: index - 1)
                    joins = candidate.joiners > 0 && drawsAsOne(candidate.text)
                }
                takesTone = scalar.properties.isEmojiModifierBase
            } else if isShown(scalar), !hidden {
                result.append(scalar)
                reset()
                previous = scalar
                takesMark = markBases.contains(scalar.value)
            } else {
                appendEscape(scalar, to: &result)
                reset()
            }
        }
        return String(result)
    }

    private static func isShown(_ scalar: Unicode.Scalar) -> Bool {
        if (0x20...0x7E).contains(scalar.value) { return true }
        guard shown.contains(where: { $0.contains(scalar.value) }), !withheld.contains(where: { $0.contains(scalar.value) }) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }

    private static func isPicture(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && !scalar.properties.isEmojiModifier && !isRegional(scalar)
            && pictures.contains { $0.contains(scalar.value) } && scalar.properties.generalCategory != .unassigned
            && !withheld.contains { $0.contains(scalar.value) }
    }

    private static func isLookalike(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x80 && (lookalikes?.contains(scalar.value) ?? true)
    }

    /// Whether any scalar of `text` reads as ASCII, whatever it stands beside: of `lookalikes` or `drawnLikeASCII`.
    static func hasLookalike(_ text: String) -> Bool {
        text.unicodeScalars.contains { isLookalike($0) || drawnLikeASCII.contains($0.value) }
    }

    /// A scalar of the input, in form C unless its own form C is another, and whether it is written out for reading as ASCII.
    private struct Token {
        let scalar: Unicode.Scalar
        let changes: Bool
        var hidden = false
    }

    /// Marks the look-alikes that are written out, run by run; the rule is in `escape`. Without the checker every scalar past
    /// ASCII is one.
    private static func hideLookalikes(_ tokens: inout [Token]) {
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
        func like(_ scalar: Unicode.Scalar) -> Bool { isLookalike(scalar) || drawnLikeASCII.contains(scalar.value) }
        func inRun(_ token: Token) -> Bool { !token.changes && ((0x21...0x7E).contains(token.scalar.value) || like(token.scalar)) }
        func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
            default: return false
            }
        }
        guard lookalikes != nil else {
            for at in tokens.indices where tokens[at].scalar.value >= 0x80 { tokens[at].hidden = true }
            return
        }
        var start = 0
        while start < tokens.count {
            guard inRun(tokens[start]) else { start += 1; continue }
            var end = start
            while end < tokens.count, inRun(tokens[end]) { end += 1 }
            var hide = tokens[start..<end].contains { isAlphanumeric($0.scalar) }
            if !hide {
                // A punctuation mark or symbol between two look-alikes: the run is a dotted, slashed or joined name made of them.
                for at in start..<end where at > start && at + 1 < end {
                    let scalar = tokens[at].scalar
                    if (scalar.value < 0x80 || isPunctuationOrSymbol(scalar)) && like(tokens[at - 1].scalar) && like(tokens[at + 1].scalar) { hide = true; break }
                }
            }
            if hide { for at in start..<end where like(tokens[at].scalar) { tokens[at].hidden = true } }
            start = end
        }
    }

    /// Whether `control`, right after `picture`, stays: a selector or a skin tone that makes CoreText draw the picture
    /// differently in the card's font. The colour selector never stays after a picture that is in colour already, and a tone
    /// only after one that takes it.
    private static func keeps(_ control: Unicode.Scalar, after picture: Unicode.Scalar) -> Bool {
        switch control.value {
        case 0xFE0F: return !picture.properties.isEmojiPresentation && changesDrawing(picture, with: control)
        case 0xFE0E: return changesDrawing(picture, with: control)
        case 0x1F3FB...0x1F3FF: return picture.properties.isEmojiModifierBase && changesDrawing(picture, with: control)
        default: return false
        }
    }

    /// The pictures from `tokens[start]` that `escape` would join, with their selectors and tones, and how many joiners hold them.
    /// A colour selector is counted after any picture that isn't in colour already: it stays only if the whole is drawn as one.
    private static func chain(_ tokens: [Token], from start: Int) -> (text: String, joiners: Int) {
        var text = String.UnicodeScalarView(), joiners = 0, index = start
        func kept(_ at: Int, _ test: (Unicode.Scalar) -> Bool) -> Bool {
            at < tokens.count && !tokens[at].changes && !tokens[at].hidden && test(tokens[at].scalar)
        }
        while true {
            let picture = tokens[index].scalar
            text.append(picture)
            index += 1
            if kept(index, { ($0.value == 0xFE0E || $0.value == 0xFE0F) && (keeps($0, after: picture) || ($0.value == 0xFE0F && !picture.properties.isEmojiPresentation)) }) {
                text.append(tokens[index].scalar)
                index += 1
            } else if kept(index, { (0x1F3FB...0x1F3FF).contains($0.value) && keeps($0, after: picture) }) {
                text.append(tokens[index].scalar)
                index += 1
            }
            guard joiners < maxJoiners, kept(index, { $0.value == 0x200D }), kept(index + 1, isPicture) else { break }
            text.append("\u{200D}")
            joiners += 1
            index += 1
        }
        return (String(text), joiners)
    }

    /// What CoreText draws `text` as in the card's code font: the font and glyph of each one that takes room. A selector may
    /// leave a glyph of no width behind, which is not a drawing.
    private static func drawing(_ text: String) -> [String] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: PermissionLayout.codeFont]))
        var drawn: [String] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName].map { CTFontCopyPostScriptName($0 as! CTFont) as String } ?? ""
            for (glyph, advance) in zip(glyphs, advances) where advance.width > 0 { drawn.append("\(font):\(glyph)") }
        }
        return drawn
    }

    /// Whether `picture` is drawn differently with `control` after it, by pair. Asked of CoreText once each; the cache stops
    /// growing at a few thousand.
    private static let controls = OSAllocatedUnfairLock(initialState: [String: Bool]())

    private static func changesDrawing(_ picture: Unicode.Scalar, with control: Unicode.Scalar) -> Bool {
        let key = String(picture) + String(control)
        if let known = controls.withLock({ $0[key] }) { return known }
        let differs = drawing(String(picture)) != drawing(key)
        controls.withLock { if $0.count < 4_096 { $0[key] = differs } }
        return differs
    }

    /// Whether the card's font draws `sequence` as one glyph that exists.
    private static func drawsAsOne(_ sequence: String) -> Bool {
        if let known = sequences.withLock({ $0[sequence] }) { return known }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sequence, attributes: [.font: PermissionLayout.codeFont]))
        var glyph: CGGlyph = 0
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1 {
            CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyph)
        }
        let drawn = glyph != 0
        sequences.withLock { if $0.count < 4_096 { $0[sequence] = drawn } }
        return drawn
    }

    private static func isRegional(_ scalar: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(scalar.value) }

    private static func isKeycapBase(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || scalar == "#" || scalar == "*"
    }

    /// Every line of `text` between U+2066 and U+2069, so letters that read right to left can't turn the line around or
    /// reorder the clauses around them. It is applied after `escape` has written out the isolates and overrides the text
    /// itself held, in drawing and in measuring alike. A word joiner follows the isolate: without it SwiftUI breaks a
    /// line of Hangul with no spaces right after the isolate, leaving its first row empty and a row taller than measured.
    static func isolated(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { "\u{2066}\u{2060}\($0)\u{2069}" }.joined(separator: "\n")
    }

    private static func appendEscape(_ scalar: Unicode.Scalar, to result: inout String.UnicodeScalarView) {
        result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
    }

    /// `text` cut to `limit` characters with a visible mark, for what is only context.
    static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// One tool call waiting for an answer, as the card shows it. Kept in memory only.
struct PermissionPrompt: Identifiable, Equatable {
    let id: UUID
    /// "Run a command", "Edit a file", or a tool's own name as Claude Code sends it.
    let title: String
    let symbol: String
    /// The command, path, address or input in full, escaped; line breaks are line breaks. For a file it is the path and
    /// what goes into the file.
    let detail: String
    /// The tool's whole name when the title is too long to show in full, so it can be read in the scrolling text; else empty.
    let toolLine: String
    /// Facts about the call that change what it does, such as a sandbox that is off; shown above `detail`.
    let flags: [Flag]
    /// Everything else the call carries, escaped, shown after `detail` in a quieter colour: a command's description and any
    /// other field as `key: value`.
    let secondary: String
    /// The folder the session runs in.
    let folder: String
    /// What "Always allow" would add; nil when it isn't offered.
    let grant: Grant?
    /// How tall what it shows is, at the narrowest closed card and at the narrowest open panel.
    let card: PermissionLayout.Measure
    let panel: PermissionLayout.Measure

    struct Flag: Equatable {
        let text: String
        /// Drawn in the warning colour.
        let warns: Bool
    }

    init(id: UUID, title: String, symbol: String, detail: String, flags: [Flag] = [], secondary: String = "", folder: String,
         grant: Grant?) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.flags = flags
        self.secondary = secondary
        self.folder = folder
        self.grant = grant
        toolLine = PermissionLayout.titleFits(title, folder: folder) ? "" : "tool: \(title)"
        let text = PermissionText.isolated(Self.scrollText(toolLine: toolLine, flags: flags, detail: detail, secondary: secondary))
        card = PermissionLayout.measure(isolatedText: text, grant: grant, place: .card)
        panel = PermissionLayout.measure(isolatedText: text, grant: grant, place: .panel)
    }

    /// The scrolling text before its lines are isolated: the tool's name if needed, flags, detail and the rest, a line break between.
    var scrollText: String { Self.scrollText(toolLine: toolLine, flags: flags, detail: detail, secondary: secondary) }

    private static func scrollText(toolLine: String, flags: [Flag], detail: String, secondary: String) -> String {
        ([toolLine].filter { !$0.isEmpty } + flags.map(\.text) + [detail, secondary].filter { !$0.isEmpty }).joined(separator: "\n")
    }

    func measure(_ place: PermissionLayout.Place) -> PermissionLayout.Measure {
        place == .card ? card : panel
    }

    /// The one `addRules` suggestion, and only when everything it would add can be shown as it is.
    struct Grant: Equatable {
        enum Place: String {
            case localSettings, projectSettings, userSettings, session

            /// Completes "Always allow saves this …".
            var phrase: String {
                switch self {
                case .localSettings: String(localized: "in this project, just for you")
                case .projectSettings: String(localized: "in this project")
                case .userSettings: String(localized: "everywhere")
                case .session: String(localized: "for this session")
                }
            }
        }

        let rules: [String]
        let place: Place

        static let maxRules = 3
        /// Rows the rules may take on the card; a suggestion that needs more is not offered.
        static let maxRuleRows = 3

        var caption: String { String(localized: "Always allow saves this \(place.phrase)") }
    }

    /// What is too long to show in full is not taken: the terminal asks, and shows all of it. Counted in Unicode scalars.
    static let detailLimit = 20_000
    static let titleLimit = 120

    struct Parsed {
        let prompt: PermissionPrompt
        /// The `addRules` suggestion "Always allow" echoes back; nil unless the prompt offers it.
        let suggestion: [String: Any]?
    }

    /// Questions and plan approvals are answered in the terminal, and so is anything unreadable.
    private static let terminalOnly: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func parse(_ body: Data) -> Parsed? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              json["hook_event_name"] as? String == "PermissionRequest",
              let tool = json["tool_name"] as? String, !tool.isEmpty, !terminalOnly.contains(tool) else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let described = describe(tool: tool, input: input)
        let detail = PermissionText.escape(described.detail, multiline: true)
        let secondary = PermissionText.escape(described.secondary, multiline: true)
        let shownTitle = PermissionText.escape(described.title, multiline: false)
        let shown = detail.unicodeScalars.count + secondary.unicodeScalars.count + described.flags.reduce(0) { $0 + $1.text.unicodeScalars.count }
        guard shown <= detailLimit, shownTitle.unicodeScalars.count <= titleLimit else { return nil }
        let suggestion = addRulesSuggestion(in: json["permission_suggestions"])
        let grant = suggestion.flatMap(grant(from:))
        let folder = (json["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        let prompt = PermissionPrompt(id: UUID(), title: shownTitle, symbol: described.symbol, detail: detail, flags: described.flags,
                                      secondary: secondary,
                                      folder: PermissionText.clipped(PermissionText.escape(folder, multiline: false), limit: 80),
                                      grant: grant)
        return Parsed(prompt: prompt, suggestion: grant == nil ? nil : suggestion)
    }

    private struct Described {
        var title: String
        var symbol: String
        var detail: String
        var flags: [Flag] = []
        var secondary = ""
    }

    /// A known tool says what it does in plain words, shows the field that says what it acts on and the text it would put
    /// there, and lists every other field it was given; any other tool, or a known one whose field isn't the text it
    /// should be, shows its own name and its whole input.
    private static func describe(tool: String, input: [String: Any]) -> Described {
        func label(_ name: String) -> String {
            switch name {
            case "old_string": "old"
            case "new_string": "new"
            default: name
            }
        }
        func known(_ key: String, _ title: String, _ symbol: String, texts: [String] = [], flagged: Bool = false) -> Described? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            var rest = input
            rest[key] = nil
            var described = Described(title: title, symbol: symbol, detail: value)
            for name in texts {
                guard let text = rest[name] as? String else { continue }
                described.detail += "\n\(label(name)):\n\(text)"
                rest[name] = nil
            }
            if let edits = rest["edits"] as? [Any], !edits.isEmpty, edits.allSatisfy({ $0 is [String: Any] }) {
                for (index, edit) in edits.enumerated() {
                    var fields = edit as? [String: Any] ?? [:]
                    described.detail += "\nedit \(index + 1) of \(edits.count):"
                    for name in ["old_string", "new_string"] {
                        guard let text = fields[name] as? String else { continue }
                        described.detail += "\n\(label(name)):\n\(text)"
                        fields[name] = nil
                    }
                    if !fields.isEmpty { described.detail += "\n" + listing(fields).joined(separator: "\n") }
                }
                rest["edits"] = nil
            }
            var extra: [String] = []
            if flagged {
                if let value = rest["dangerouslyDisableSandbox"], isTruthy(value) {
                    described.flags.append(Flag(text: String(localized: "Sandbox off"), warns: true))
                    // A real true is said by the flag; any other form is listed as it came as well.
                    if isTrue(value) { rest["dangerouslyDisableSandbox"] = nil }
                }
                if isTrue(rest["run_in_background"]) {
                    described.flags.append(Flag(text: String(localized: "Runs in the background"), warns: false))
                    rest["run_in_background"] = nil
                }
                if let note = rest["description"] as? String, !note.isEmpty {
                    extra.append("description: \(note)")
                    rest["description"] = nil
                }
            }
            described.secondary = (extra + listing(rest)).joined(separator: "\n")
            return described
        }
        let described: Described? = switch tool {
        case "Bash": known("command", String(localized: "Run a command"), "terminal", flagged: true)
        case "Edit", "MultiEdit": known("file_path", String(localized: "Edit a file"), "pencil", texts: ["old_string", "new_string"])
        case "Write": known("file_path", String(localized: "Write a file"), "doc.badge.plus", texts: ["content"])
        case "NotebookEdit": known("notebook_path", String(localized: "Edit a notebook"), "pencil", texts: ["new_source"])
        case "Read": known("file_path", String(localized: "Read a file"), "doc.text")
        case "WebFetch": known("url", String(localized: "Fetch a web page"), "globe")
        case "WebSearch": known("query", String(localized: "Search the web"), "magnifyingglass")
        default: nil
        }
        if let described { return described }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Described(title: tool, symbol: "puzzlepiece.extension", detail: input.isEmpty ? "" : json)
    }

    /// A real JSON `true`.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Anything a tool may read as true: `true`, the string "true" in any case, a number that isn't zero.
    private static func isTruthy(_ value: Any) -> Bool {
        if isTrue(value) { return true }
        if let text = value as? String { return text.lowercased() == "true" }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue != 0
    }

    /// Every field as `key: value`, in key order; text as it is, anything else as JSON.
    private static func listing(_ fields: [String: Any]) -> [String] {
        fields.keys.sorted().map { key in
            let value = fields[key] as Any
            if let text = value as? String { return "\(key): \(text)" }
            let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) }
            return "\(key): \(json ?? "\(value)")"
        }
    }

    /// The first suggestion that adds allow rules; a mode change is never offered.
    static func addRulesSuggestion(in value: Any?) -> [String: Any]? {
        (value as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first { entry in
            entry["type"] as? String == "addRules" && entry["behavior"] as? String == "allow"
                && !((entry["rules"] as? [Any]) ?? []).isEmpty
        }
    }

    /// Every rule as Claude Code writes it, or nil when any part of the suggestion can't be shown as it is: a rule that
    /// needs escaping or holds a scalar that reads as ASCII, wherever it stands, one that is missing or odd, a key nobody has
    /// seen, too many rules, rules that take more rows than the card has for them, or a place that isn't known.
    static func grant(from suggestion: [String: Any]) -> Grant? {
        guard Set(suggestion.keys).isSubset(of: ["type", "behavior", "rules", "destination"]),
              let place = (suggestion["destination"] as? String).flatMap(Grant.Place.init(rawValue:)),
              let entries = suggestion["rules"] as? [Any], (1...Grant.maxRules).contains(entries.count) else { return nil }
        var rules: [String] = []
        for entry in entries {
            guard let rule = entry as? [String: Any], Set(rule.keys).isSubset(of: ["toolName", "ruleContent"]),
                  let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
            var text = tool
            if let content = rule["ruleContent"] {
                guard let content = content as? String, !content.isEmpty else { return nil }
                text += "(\(content))"
            }
            guard PermissionText.escape(text, multiline: false) == text, !PermissionText.hasLookalike(text) else { return nil }
            rules.append(text)
        }
        let grant = Grant(rules: rules, place: place)
        guard PermissionLayout.offers(grant, place: .card) else { return nil }
        return grant
    }

    #if DEBUG
    /// `--demo-permission` shows this.
    static var demo: PermissionPrompt {
        PermissionPrompt(id: UUID(), title: String(localized: "Run a command"), symbol: "terminal",
                         detail: "npm run build && npm test -- --coverage", folder: "nunsseop-web",
                         grant: Grant(rules: ["Bash(npm run *)"], place: .localSettings))
    }
    #endif
}

/// Keeps a click from answering a prompt it was not meant for: a card that has just appeared, or just changed, may be
/// under a click aimed at something else. Buttons ignore clicks for `delay` after that, and a click whose mouse-down
/// came before the end of it doesn't count either, however late its mouse-up is.
@MainActor
final class PermissionClickGate: ObservableObject {
    static let delay: TimeInterval = 0.7

    /// Whether the buttons are live; they look dimmed until then.
    @Published private(set) var isReady = false
    private let clock: () -> TimeInterval
    private var readyAt = TimeInterval.infinity
    private var pressedAt: TimeInterval?
    private var wake: DispatchWorkItem?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// The card appeared or its prompt changed.
    func arm() {
        readyAt = clock() + Self.delay
        isReady = false
        schedule(after: Self.delay)
    }

    /// The mouse went down on a button.
    func pressBegan() {
        pressedAt = clock()
    }

    /// The mouse came up. The click's own action runs first, so what it saw is dropped a moment later.
    func pressEnded() {
        let pressed = pressedAt
        DispatchQueue.main.async { [self] in
            if pressedAt == pressed { pressedAt = nil }
        }
    }

    /// Whether the click that just happened counts. A press and a release are two clocks apart in a test, so both are read.
    func accepts() -> Bool {
        refresh()
        guard isReady else { return false }
        if let pressedAt, pressedAt < readyAt { return false }
        return true
    }

    /// `isReady` from the clock.
    func refresh() {
        isReady = clock() >= readyAt
    }

    private func schedule(after seconds: TimeInterval) {
        wake?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if !self.isReady { self.schedule(after: max(self.readyAt - self.clock(), 0.02)) }
            }
        }
        wake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The prompts waiting for an answer, oldest first. A prompt leaves when it is answered or when its hook is gone
/// (the terminal answered first, Claude Code stopped it, or it timed out).
@MainActor
final class PermissionBoard: ObservableObject {
    @Published private(set) var prompts: [PermissionPrompt] = [] {
        didSet { if prompts.first != oldValue.first, prompts.first != nil { gate.arm() } }
    }
    let gate: PermissionClickGate
    /// Hands an answer to the server, which holds the hook's connection.
    var onAnswer: ((UUID, PermissionAnswer) -> Void)?

    init(gate: PermissionClickGate? = nil) {
        self.gate = gate ?? PermissionClickGate()
    }

    var current: PermissionPrompt? { prompts.first }

    func add(_ prompt: PermissionPrompt) {
        prompts.append(prompt)
    }

    /// An answer by a click on the card, which counts only when the gate lets it.
    func answerByClick(_ prompt: PermissionPrompt, _ answer: PermissionAnswer) {
        guard gate.accepts() else { return }
        self.answer(prompt, answer)
    }

    func answer(_ prompt: PermissionPrompt, _ answer: PermissionAnswer) {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        remove(prompt.id)
        onAnswer?(prompt.id, answer)
    }

    func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    func clear() {
        prompts = []
    }
}
