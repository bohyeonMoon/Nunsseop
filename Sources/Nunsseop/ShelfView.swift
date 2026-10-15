import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The shelf: the files on it as a list on the left, the one under the pointer on the right. Files dropped over the list go on the
/// shelf; dropped over the right side they go straight to AirDrop (see `NotchView.airDropRect`).
struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    let isDropTargeted: Bool
    let isAirDropTargeted: Bool
    @State private var selection = DetailSelection<UUID>()

    /// The list's share of the width; the rest is where a drop goes to AirDrop.
    static let listFraction: CGFloat = 0.4

    var body: some View {
        PanelSplit(leftFraction: Self.listFraction) {
            if shelf.items.isEmpty { dropBox } else { list }
        } right: {
            if shelf.items.isEmpty || isAirDropTargeted {
                airDrop
            } else if let shown = selection.current(in: shelf.items.map(\.id)).flatMap({ id in shelf.items.first { $0.id == id } }) {
                ShelfDetail(item: shown) { shelf.remove(shown) }
            }
        }
        .foregroundStyle(.white)
    }

    private var dropOutline: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.white.opacity(isDropTargeted ? 0.9 : 0.35))
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(isDropTargeted ? 0.12 : 0)))
    }

    private var dropBox: some View {
        ZStack {
            dropOutline
            VStack(spacing: 4) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).accessibilityHidden(true)
                Text("Drop files here").font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu { Button("Quit Nunsseop") { NSApp.terminate(nil) } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            PanelList(items: shelf.items, selection: $selection) { item, selected in
                ShelfRow(item: item, selected: selected) { shelf.remove(item) }
            }
            PanelHLine()
            HStack(spacing: 2) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 11)).foregroundStyle(PanelInk.hint)
                    .padding(.leading, 8).accessibilityHidden(true)
                Text("Drop files here").font(.system(size: 11)).foregroundStyle(PanelInk.hint).padding(.leading, 4)
                Spacer(minLength: 0)
                PanelIconButton(symbol: "dot.radiowaves.left.and.right", title: String(localized: "AirDrop All")) {
                    ShelfSharing.airDrop(shelf.items.map(\.url))
                }
                Menu {
                    ShareLink(items: shelf.items.map(\.url)) { Text("Share All…") }
                    Button("Clear Shelf") { shelf.removeAll() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text("More")).accessibilityLabel(Text("More"))
            }
            .frame(height: 27)
        }
        .overlay { if isDropTargeted { dropOutline.allowsHitTesting(false) } }
        .contextMenu {
            Button("AirDrop All") { ShelfSharing.airDrop(shelf.items.map(\.url)) }
            ShareLink(items: shelf.items.map(\.url)) { Text("Share All…") }
            Button("Clear Shelf") { shelf.removeAll() }
            Button("Quit Nunsseop") { NSApp.terminate(nil) }
        }
    }

    /// What dropping on this side does; clicking it sends everything on the shelf.
    private var airDrop: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20)).frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.1))).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("AirDrop").font(.system(size: 13, weight: .semibold))
                Text("Drop files to send with AirDrop, or click to send everything on the shelf")
                    .font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(3)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if isAirDropTargeted {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ShelfSharing.airDrop(shelf.items.map(\.url)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help(Text("Drop files to send with AirDrop, or click to send everything on the shelf"))
    }
}

/// What the shelf shows about a file without opening it: its kind, and its size unless it is a folder.
private struct ShelfFacts {
    var kind: String?
    var size: String?

    static func read(_ url: URL) -> ShelfFacts {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        let size = values?.isDirectory == true ? nil : values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return ShelfFacts(kind: values?.localizedTypeDescription, size: size)
    }
}

private struct ShelfRow: View {
    let item: ShelfItem
    let selected: Bool
    let onRemove: () -> Void
    @State private var size: String?

    var body: some View {
        LedgerRow(selected: selected) {
            LedgerLine(title: item.url.lastPathComponent, trailing: size, truncation: .middle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            }
        }
        .task(id: item.url) { size = ShelfFacts.read(item.url).size }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("AirDrop") { ShelfSharing.airDrop([item.url]) }
            ShareLink(item: item.url) { Text("Share…") }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Remove from Shelf", action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .help(item.url.path)
    }
}

private struct ShelfDetail: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var facts = ShelfFacts()

    private static let previewSize = CGSize(width: 118, height: 78)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    let summary = [facts.kind, facts.size].compactMap { $0 }.joined(separator: " · ")
                    if !summary.isEmpty { quiet(summary) }
                    quiet((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                }
            }
            HStack(spacing: 6) {
                PanelAction(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", style: .primary) { ShelfSharing.airDrop([item.url]) }
                ShareAction(url: item.url)
                PanelAction(title: "Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                PanelAction(title: "Remove", symbol: "xmark", action: onRemove)
            }
            Text("Drag the file out of the shelf to move or copy it").font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1)
        }
        .task(id: item.url) {
            thumbnail = nil
            facts = ShelfFacts.read(item.url)
            thumbnail = await Self.thumbnail(for: item.url)
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 11)).foregroundStyle(PanelInk.secondary).lineLimit(1).truncationMode(.middle)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13))
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 44, height: 44)
            }
            RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.22), lineWidth: 0.75)
        }
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .accessibilityHidden(true)
    }

    /// A Quick Look preview of the file (screenshots, images, PDFs, videos), or nil to fall back to its icon.
    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: previewSize, scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// Share looks like a `PanelAction`, but a `ShareLink` brings its own button.
private struct ShareAction: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        ShareLink(item: url) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 11)).accessibilityHidden(true)
                Text("Share").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.8))
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(.white.opacity(hovering ? 0.08 : 0)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 0.75))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum ShelfSharing {
    @MainActor
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
    }
}

extension ShelfStore {
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self.add([url]) }
            }
        }
        return true
    }
}
