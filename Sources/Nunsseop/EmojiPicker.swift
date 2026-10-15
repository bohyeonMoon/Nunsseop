import AppKit
import SwiftUI

/// The Unicode blocks the picker draws from, as the list on the left, and what was copied lately.
enum EmojiCategory: CaseIterable, Hashable {
    case recent, emoticons, pictographs, transport, supplemental, extended, symbols, dingbats

    /// The code points of the block; Recent has none of its own.
    var range: ClosedRange<UInt32>? {
        switch self {
        case .recent: return nil
        case .emoticons: return 0x1F600...0x1F64F
        case .pictographs: return 0x1F300...0x1F5FF
        case .transport: return 0x1F680...0x1F6FF
        case .supplemental: return 0x1F900...0x1F9FF
        case .extended: return 0x1FA70...0x1FAFF
        case .symbols: return 0x2600...0x26FF
        case .dingbats: return 0x2700...0x27BF
        }
    }

    var title: String {
        switch self {
        case .recent: return String(localized: "Recent")
        case .emoticons: return String(localized: "Emoticons")
        case .pictographs: return String(localized: "Pictographs")
        case .transport: return String(localized: "Transport & map")
        case .supplemental: return String(localized: "Supplemental")
        case .extended: return String(localized: "Extended")
        case .symbols: return String(localized: "Symbols")
        case .dingbats: return String(localized: "Dingbats")
        }
    }
}

/// Every fully-qualified single-scalar emoji, searchable by its Unicode name.
@MainActor
final class EmojiModel: ObservableObject {
    struct Emoji: Identifiable, Hashable {
        var id: String { character }
        let character: String
        let name: String
        let category: EmojiCategory
    }

    @Published private(set) var recents: [String]
    /// The emoji copied a moment ago, for the picker to confirm.
    @Published private(set) var copied: String?
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard

    /// In the order the blocks were first drawn from, which the search results keep.
    private static let blocks: [EmojiCategory] = [.pictographs, .emoticons, .transport, .supplemental, .extended, .symbols, .dingbats]

    static let all: [Emoji] = {
        blocks.flatMap { category in
            (category.range ?? 0...0).compactMap { value -> Emoji? in
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                      let name = scalar.properties.name else { return nil }
                return Emoji(character: String(Character(scalar)), name: name.lowercased(), category: category)
            }
        }
    }()

    private static let byCategory = Dictionary(grouping: all, by: \.category)

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        recents = defaults.stringArray(forKey: "emojiRecents") ?? []
    }

    func results(for query: String) -> [Emoji] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return recentEmoji + Self.all.filter { !recents.contains($0.character) }
        }
        return Self.all.filter { $0.name.contains(q) }
    }

    /// What the picker shows: a search looks through every category, otherwise it is the chosen category's.
    func shown(in category: EmojiCategory, query: String) -> [Emoji] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return results(for: q) }
        return category == .recent ? recentEmoji : Self.byCategory[category] ?? []
    }

    private var recentEmoji: [Emoji] {
        recents.compactMap { r in Self.all.first { $0.character == r } }
    }

    func copy(_ emoji: Emoji) {
        pasteboard.clearContents()
        pasteboard.setString(emoji.character, forType: .string)
        recents.removeAll { $0 == emoji.character }
        recents.insert(emoji.character, at: 0)
        if recents.count > 18 { recents.removeLast(recents.count - 18) }
        defaults.set(recents, forKey: "emojiRecents")
        copied = emoji.character
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copied == emoji.character { copied = nil }
        }
    }
}

/// A list of categories on the left, the search field and the emoji of the chosen category (or of the search) on the right.
struct EmojiTab: View {
    @ObservedObject var model: EmojiModel
    @State private var query = ""
    @State private var chosen: EmojiCategory?

    /// What the list shows when nothing was chosen: Recent, unless nothing was copied yet.
    private var category: EmojiCategory { chosen ?? (model.recents.isEmpty ? .emoticons : .recent) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            categories.padding(.trailing, 6).frame(width: 150)
            PanelVLine().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                searchRow
                grid
            }
            .padding(.leading, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
    }

    private var categories: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(EmojiCategory.allCases, id: \.self) { item in
                    let selected = !searching && item == category
                    Button { chosen = item; query = "" } label: {
                        LedgerRow(selected: selected) {
                            HStack {
                                Text.panel(item.title, size: 12, weight: .semibold, opacity: selected ? 1 : 0.75).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .panelFadeBottom()
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PanelInk.secondary).accessibilityHidden(true)
                TextField("Search emoji (English names)", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: 214)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            Spacer(minLength: 0)
            if let copied = model.copied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
                    Text("Copied \(copied)").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        let shown = model.shown(in: category, query: query)
        if shown.isEmpty {
            Text(searching ? String(localized: "No emoji found") : String(localized: "Emoji you copy show up here"))
                .font(.system(size: 12)).foregroundStyle(PanelInk.hint)
                .padding(.top, 8).padding(.leading, 4)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 2)], alignment: .leading, spacing: 2) {
                    ForEach(shown) { emoji in
                        EmojiCell(emoji: emoji, copied: model.copied == emoji.character) { model.copy(emoji) }
                    }
                }
            }
            .panelFadeBottom(12)
        }
    }
}

/// One emoji: a 28 pt square, lit under the pointer, ringed for a moment once it is copied.
private struct EmojiCell: View {
    let emoji: EmojiModel.Emoji
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: emoji.character).font(.system(size: 17)).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.1 : 0)))
                .overlay { if copied { RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.6), lineWidth: 1) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(emoji.name)
        .accessibilityLabel(emoji.name)
    }
}
