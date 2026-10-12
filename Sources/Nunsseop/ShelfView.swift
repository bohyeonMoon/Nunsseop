import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    let isDropTargeted: Bool
    let isAirDropTargeted: Bool

    static let airDropWidth: CGFloat = 76

    /// A tile's thumbnail for a shelf this tall: as large as leaves room for its two-line name and some air, so a
    /// few files don't sit small in an empty shelf.
    static func iconSize(forHeight height: CGFloat) -> CGFloat {
        min(max(height - 64, 40), maxIcon)
    }

    static let maxIcon: CGFloat = 84

    var body: some View {
        HStack(spacing: 8) {
            shelfArea
            AirDropTile(shelf: shelf, targeted: isAirDropTargeted)
                .frame(width: Self.airDropWidth)
        }
    }

    private var shelfArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(isDropTargeted ? 0.9 : 0.25))
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(isDropTargeted ? 0.12 : 0.04)))

            if shelf.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 18))
                    Text("Drop files here").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.55))
            } else {
                GeometryReader { geometry in
                    let icon = Self.iconSize(forHeight: geometry.size.height)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item, icon: icon) { shelf.remove(item) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: geometry.size.height)
                    }
                }
            }
        }
        .contextMenu {
            if !shelf.items.isEmpty {
                Button("AirDrop All") { ShelfSharing.airDrop(shelf.items.map(\.url)) }
                ShareLink(items: shelf.items.map(\.url)) { Text("Share All…") }
                Button("Clear Shelf") { shelf.removeAll() }
            }
            Button("Quit Nunsseop") { NSApp.terminate(nil) }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let icon: CGFloat
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                }
            }
            .frame(width: icon, height: icon)
            .task(id: item.url) { thumbnail = await Self.thumbnail(for: item.url) }
            Text(item.url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: max(64, icon + 16))
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovering ? 0.12 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("AirDrop") { ShelfSharing.airDrop([item.url]) }
            ShareLink(item: item.url) { Text("Share…") }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Remove from Shelf", action: onRemove)
        }
        .help(item.url.path)
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

/// Drop files here to send them with AirDrop; click to send everything on the shelf.
private struct AirDropTile: View {
    @ObservedObject var shelf: ShelfStore
    let targeted: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .medium))
            Text("AirDrop").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(targeted || hovering ? 1 : 0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(targeted ? 0.45 : (hovering ? 0.22 : 0.12))))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .onTapGesture { ShelfSharing.airDrop(shelf.items.map(\.url)) }
        .help(Text("Drop files to send with AirDrop, or click to send everything on the shelf"))
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

private extension ShelfTile {
    /// A Quick Look preview of the file (screenshots, images, PDFs, videos), or nil to fall back to its icon.
    static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: ShelfView.maxIcon, height: ShelfView.maxIcon),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
