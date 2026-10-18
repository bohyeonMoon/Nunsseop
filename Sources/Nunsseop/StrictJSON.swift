import Foundation

/// JSON read for an approval card, where what the card shows must be what the tool runs. Foundation keeps one value of a key an object
/// has twice, and a tool's own parser may keep the other (JavaScript's `JSON.parse` keeps the last): a text with the same key twice,
/// at any depth, is no text to show a card for.
enum StrictJSON {
    /// The object a text holds; nil when it holds anything else, is no JSON, or has an object with a key twice.
    static func object(from text: String) -> [String: Any]? { object(from: Data(text.utf8)) }

    static func object(from data: Data) -> [String: Any]? {
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !hasDuplicateKeys(data) else { return nil }
        return value
    }

    /// Whether some object in the text has a key twice (keys are compared once their escapes are read, and as Swift compares strings, which
    /// is by canonical equivalence: a key spelled two ways of the same letters counts as twice). Text that is not well formed counts too.
    static func hasDuplicateKeys(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var at = 0
        func skip() { while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 || bytes[at] == 0x0A || bytes[at] == 0x0D { at += 1 } }
        /// At an opening quote: the string, escapes read; nil when it never ends or can't be read.
        func string() -> String? {
            let start = at
            at += 1
            while at < bytes.count {
                if bytes[at] == 0x5C { at += 2; continue }
                if bytes[at] == 0x22 {
                    at += 1
                    return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<min(at, bytes.count)]), options: .fragmentsAllowed)) as? String
                }
                at += 1
            }
            return nil
        }
        /// Whether the value that starts here is well formed and has no object with a key twice.
        func value(_ depth: Int) -> Bool {
            guard depth < 64 else { return false }
            skip()
            guard at < bytes.count else { return false }
            switch bytes[at] {
            case 0x7B:
                at += 1
                var keys = Set<String>()
                skip()
                if at < bytes.count, bytes[at] == 0x7D { at += 1; return true }
                while true {
                    skip()
                    guard at < bytes.count, bytes[at] == 0x22, let key = string(), keys.insert(key).inserted else { return false }
                    skip()
                    guard at < bytes.count, bytes[at] == 0x3A else { return false }
                    at += 1
                    guard value(depth + 1) else { return false }
                    skip()
                    guard at < bytes.count else { return false }
                    if bytes[at] == 0x2C { at += 1; continue }
                    if bytes[at] == 0x7D { at += 1; return true }
                    return false
                }
            case 0x5B:
                at += 1
                skip()
                if at < bytes.count, bytes[at] == 0x5D { at += 1; return true }
                while true {
                    guard value(depth + 1) else { return false }
                    skip()
                    guard at < bytes.count else { return false }
                    if bytes[at] == 0x2C { at += 1; continue }
                    if bytes[at] == 0x5D { at += 1; return true }
                    return false
                }
            case 0x22:
                return string() != nil
            default:
                let start = at
                while at < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
                return at > start
            }
        }
        guard value(0) else { return true }
        skip()
        return at != bytes.count
    }
}
