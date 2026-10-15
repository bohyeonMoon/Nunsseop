import Combine
import SwiftUI

// The look the tabs share ("Panels"): ledger rows like the Agents tab's, hairlines instead of cards, a list on the left with the
// item under the pointer on the right, and dashboards as columns of a label, a number and a 3 pt bar. Pure black, white at fixed
// opacities; orange (needs you) and green (working) are the only colours that mean something.

enum PanelInk {
    static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
    static let working = Color(red: 0.31, green: 0.82, blue: 0.47)
    static let secondary = Color.white.opacity(0.6)
    static let hint = Color.white.opacity(0.65)
    static let hair = Color.white.opacity(0.24)
}

extension Text {
    /// A line of a panel: white at `opacity`, `mono` for figures that change. The string is shown as it is.
    static func panel(_ text: String, size: CGFloat = 12, weight: Font.Weight = .regular, opacity: Double = 1, mono: Bool = false) -> Text {
        Text(verbatim: text)
            .font(mono ? .system(size: size, weight: weight).monospacedDigit() : .system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
    }
}

// MARK: - Lines

/// One device pixel thick: 0.5 pt on a Retina display, 1 pt on a plain one, where half a point would fall between pixels.
struct PanelHLine: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(PanelInk.hair).frame(height: 1 / max(1, scale)).accessibilityHidden(true) }
}

struct PanelVLine: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(PanelInk.hair).frame(width: 1 / max(1, scale)).accessibilityHidden(true) }
}

/// A key as a keycap; `dim` when it does nothing now.
struct PanelKeycap: View {
    let key: String
    var dim = false
    init(_ key: String, dim: Bool = false) { self.key = key; self.dim = dim }

    var body: some View {
        Text(verbatim: key).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(dim ? 0.45 : 0.7))
            .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(dim ? 0.05 : 0.1)))
            .accessibilityHidden(true)
    }
}

/// A panel or column label: quiet, sentence case, 16 pt tall.
struct PanelCaption: View {
    let text: String
    var symbol: String?
    init(_ text: String, symbol: String? = nil) { self.text = text; self.symbol = symbol }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)).accessibilityHidden(true) }
            Text(verbatim: text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(PanelInk.secondary)
        .frame(height: 16)
    }
}

/// The thin bar: 3 pt, white on a faint track. `tint` only when the level means something, and then a `tick` at the threshold too,
/// so a high level reads by position and not by colour alone.
struct PanelMeter: View {
    let fraction: Double
    var tint: Color = .white.opacity(0.75)
    var tick: Double?

    var body: some View {
        GeometryReader { p in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                Capsule().fill(tint).frame(width: max(3, p.size.width * min(1, max(0, fraction))), height: 3)
                if let tick {
                    Rectangle().fill(.white.opacity(0.9)).frame(width: 1, height: 7).offset(x: p.size.width * tick - 0.5)
                }
            }
            .frame(width: p.size.width, height: p.size.height, alignment: .leading)
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A list that scrolls ends in a short fade, so a row cut by the edge reads as "more below".
    func panelFadeBottom(_ height: CGFloat = 16) -> some View {
        mask(VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height)
        })
    }
}

// MARK: - Buttons

/// An icon button with no label of its own: 24 x 24, hit target included, brighter under the pointer or when `hot` (the selected
/// row's). `reason` disables it, shows a dashed outline instead of only a dimmer icon, and is its tooltip.
struct PanelIconButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 12
    var hot = false
    var reason: String?
    let action: () -> Void
    @State private var hovering = false

    private var enabled: Bool { reason == nil }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
                .foregroundStyle(.white.opacity(enabled ? (hot || hovering ? 0.95 : 0.65) : 0.4))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(enabled && (hot || hovering) ? 0.1 : 0)))
                .overlay {
                    if !enabled { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(reason ?? title)
        .accessibilityLabel(title)
        .accessibilityHint(reason ?? "")
    }
}

/// A labelled action: a 24 pt capsule with an icon, the title and, if the key does it, the key. `primary` is the default action.
struct PanelAction: View {
    enum Style { case primary, quiet }
    let title: LocalizedStringKey
    var symbol: String?
    var key: String?
    var style: Style = .quiet
    /// Why it is disabled; nil when it works.
    var reason: String?
    /// The tooltip when it works, if the title says too little.
    var hint: String?
    let action: () -> Void
    @State private var hovering = false

    private var enabled: Bool { reason == nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if let key { PanelKeycap(key, dim: !enabled) }
            }
            .foregroundStyle(.white.opacity(enabled ? (style == .primary || hovering ? 0.95 : 0.8) : 0.45))
            .padding(.leading, 8).padding(.trailing, key == nil ? 8 : 4).frame(height: 24)
            .background {
                if style == .primary || (enabled && hovering) {
                    Capsule().fill(.white.opacity(style == .primary ? (hovering ? 0.2 : 0.14) : 0.08))
                }
            }
            .overlay {
                if style == .quiet {
                    if enabled {
                        Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 0.75)
                    } else {
                        Capsule().strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                    }
                }
            }
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help((reason ?? hint).map { Text(verbatim: $0) } ?? Text(title))
    }
}

/// The switch with its state in words ("On" / "Off"), so it reads without colour.
struct PanelOnOff: View {
    @Binding var isOn: Bool
    /// What it switches, for VoiceOver.
    let title: LocalizedStringKey

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? PanelInk.working : Color.white.opacity(0.22)).frame(width: 30, height: 18)
                    Circle().fill(isOn ? Color.black.opacity(0.85) : Color.white).frame(width: 14, height: 14).padding(2)
                }
                .frame(width: 30, height: 24)
                Text(isOn ? "On" : "Off").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Ledger rows

/// A ledger row, 24 pt: padded 8, a faint surface under the pointer, and when `selected` the stronger one with a thin border
/// (white 0.4 on the panel is 3.7:1) that the Agents tab uses.
struct LedgerRow<Content: View>: View {
    var selected = false
    var height: CGFloat = 24
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 8).frame(height: height)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.4), lineWidth: 0.75)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// An icon in a ledger row: 16 pt wide, white at 0.75.
struct PanelSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 16).accessibilityHidden(true)
    }
}

/// The line inside a ledger row: a leading icon, the title, and quiet text at the end (a size, an age).
struct LedgerLine<Lead: View>: View {
    let title: String
    var trailing: String?
    var weight: Font.Weight = .semibold
    var truncation: Text.TruncationMode = .tail
    @ViewBuilder var lead: Lead

    var body: some View {
        HStack(spacing: 8) {
            lead
            Text(verbatim: title).font(.system(size: 12, weight: weight)).lineLimit(1).truncationMode(truncation)
            Spacer(minLength: 4)
            if let trailing { Text.panel(trailing, size: 11, opacity: 0.6, mono: true).lineLimit(1).fixedSize() }
        }
    }
}

extension LedgerLine where Lead == PanelSymbol {
    init(symbol: String, title: String, trailing: String? = nil, weight: Font.Weight = .semibold, truncation: Text.TruncationMode = .tail) {
        self.init(title: title, trailing: trailing, weight: weight, truncation: truncation) { PanelSymbol(name: symbol) }
    }
}

// MARK: - Master and detail

/// A list on the left (about 40 %) and the item it shows on the right, a hairline between them.
struct PanelSplit<Left: View, Right: View>: View {
    var leftFraction: CGFloat = 0.4
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        GeometryReader { p in
            HStack(spacing: 0) {
                left.padding(.trailing, 8).frame(width: p.size.width * leftFraction, height: p.size.height, alignment: .topLeading)
                PanelVLine().padding(.vertical, 2)
                right.padding(.leading, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// The top of a detail pane: what the item is (an optional picture or icon on the left, a title, then one quiet line per fact).
struct PanelDetailHeader<Lead: View>: View {
    let title: String
    var meta: [String] = []
    var titleLines = 2
    @ViewBuilder var lead: Lead

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(titleLines)
                ForEach(Array(meta.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

extension PanelDetailHeader where Lead == EmptyView {
    init(title: String, meta: [String] = [], titleLines: Int = 2) {
        self.init(title: title, meta: meta, titleLines: titleLines) { EmptyView() }
    }
}

/// A caption on the left and a fact on the right, one line (when it was copied, how long it is).
struct PanelMetaRow: View {
    let caption: String
    var value: String?

    var body: some View {
        HStack {
            PanelCaption(caption)
            Spacer(minLength: 8)
            if let value { Text(verbatim: value).font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1) }
        }
    }
}

/// Which item the detail pane shows: the one under the pointer, else the one chosen with the arrow keys, else the first (the most
/// recent). Clicking a row acts on it at once; it does not need to select first.
struct DetailSelection<ID: Hashable> {
    private(set) var hovered: ID?
    private(set) var chosen: ID?

    func current(in ids: [ID]) -> ID? {
        if let hovered, ids.contains(hovered) { return hovered }
        if let chosen, ids.contains(chosen) { return chosen }
        return ids.first
    }

    mutating func hover(_ id: ID, inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    /// Moves the choice from what is shown now by `step` rows, stopping at the ends. The pointer's claim ends: the key wins.
    mutating func move(_ step: Int, in ids: [ID]) {
        guard !ids.isEmpty else { return }
        let from = current(in: ids).flatMap { ids.firstIndex(of: $0) } ?? 0
        chosen = ids[min(max(0, from + step), ids.count - 1)]
        hovered = nil
    }
}

/// The arrow keys of the open notch. The window's key monitor sends ↑↓ here when a tab has asked to listen, so a tab that does not
/// use them leaves them to the app that is in front.
@MainActor
enum PanelKeys {
    static let moves = PassthroughSubject<Int, Never>()
    private(set) static var listeners = 0

    static func listen() { listeners += 1 }
    static func stopListening() { listeners = max(0, listeners - 1) }

    /// True when a tab is listening and took the key.
    static func move(_ step: Int) -> Bool {
        guard listeners > 0 else { return false }
        moves.send(step)
        return true
    }
}

extension View {
    /// Makes the pointer over this row what the detail pane shows.
    func panelHover<ID: Hashable>(_ id: ID, in selection: Binding<DetailSelection<ID>>) -> some View {
        onHover { selection.wrappedValue.hover(id, inside: $0) }
    }

    /// ↑↓ move the shown item through `ids` while this view is on screen.
    func panelArrowKeys<ID: Hashable>(_ selection: Binding<DetailSelection<ID>>, ids: [ID]) -> some View {
        onAppear { PanelKeys.listen() }
            .onDisappear { PanelKeys.stopListening() }
            .onReceive(PanelKeys.moves) { selection.wrappedValue.move($0, in: ids) }
    }
}

// MARK: - Dashboards

/// Columns separated by hairlines, `gap` either side of each.
struct PanelColumns<Item, Content: View>: View {
    let items: [Item]
    let gap: CGFloat
    @ViewBuilder let content: (Item) -> Content

    init(_ items: [Item], gap: CGFloat = 12, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.gap = gap
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { PanelVLine() }
                content(item)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, index > 0 ? gap : 0)
                    .padding(.trailing, index < items.count - 1 ? gap : 0)
            }
        }
    }
}

/// A dashboard figure: a label, the number, a 3 pt bar and a caption under it.
struct PanelMetric: View {
    let label: String
    let value: String
    var unit: String?
    var caption: String
    let fraction: Double
    var captionSymbol: String?
    var tint: Color = .white.opacity(0.75)
    var tick: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelCaption(label)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text.panel(value, size: 23, weight: .semibold, mono: true)
                if let unit { Text.panel(unit, size: 12, opacity: 0.6) }
            }
            PanelMeter(fraction: fraction, tint: tint, tick: tick)
            HStack(spacing: 3) {
                if let captionSymbol { Image(systemName: captionSymbol).font(.system(size: 10)).accessibilityHidden(true) }
                Text.panel(caption, size: 11, opacity: 0.65, mono: true).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: "\(value)\(unit ?? "") \(caption)"))
    }
}

// MARK: - Lists

extension DetailSelection {
    /// The pointer leaves a row. A row that was on show stays on show: the pointer is most likely on its way to the buttons beside it,
    /// and they must act on the item it was just over, not on the first one.
    mutating func leave(_ id: ID, in ids: [ID]) {
        if current(in: ids) == id { move(0, in: ids) }
        hover(id, inside: false)
    }
}

/// The scrolling list of a master-detail tab: the pointer or ↑↓ choose which row the detail pane shows, and a row the keys chose is
/// scrolled into view. `row` gets the item and whether it is the one on show.
struct PanelList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var selection: DetailSelection<Item.ID>
    @ViewBuilder var row: (Item, Bool) -> Row

    var body: some View {
        let ids = items.map(\.id)
        let shown = selection.current(in: ids)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item, item.id == shown)
                            .id(item.id)
                            .onHover { inside in
                                if inside { selection.hover(item.id, inside: true) } else { selection.leave(item.id, in: ids) }
                            }
                    }
                }
            }
            .onChange(of: selection.chosen) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .panelFadeBottom()
        .panelArrowKeys($selection, ids: ids)
    }
}

extension Date {
    /// "3 minutes ago", "now" or "yesterday", in the display language.
    var panelAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: self, relativeTo: max(.now, self))
    }
}
