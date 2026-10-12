import AppKit
import SwiftUI
@testable import Nunsseop

/// Draws the collapsed shape's top row in-process and measures it in pixels, for the tests that check how the live
/// activity sits around the camera.
@MainActor
enum EarRender {
    /// The row's padding from the shape's wall: the top corner radius (6) and 7.
    static let wallMargin: CGFloat = 13

    struct Measure {
        /// Empty points between the left content and the camera area, and between the camera area and the right content.
        var leftGap: CGFloat
        var rightGap: CGFloat
        /// Empty points between each wall and the content nearest it.
        var leftMargin: CGFloat
        var rightMargin: CGFloat
        /// Whether anything is drawn inside the camera area.
        var intrudes: Bool
    }

    /// Renders `view` at its own size in a dark window, at the screen's scale.
    static func pixels<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Always 2x, so a point's edges land on whole pixels whatever display the tests run on.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    /// The row on black with the camera area painted magenta, so content and camera can be told apart by colour.
    static func marked<V: View>(_ content: V, left: CGFloat, right: CGFloat, camera: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Color(red: 1, green: 0, blue: 1)
                .frame(width: camera, height: height)
                .offset(x: left)
            content
                .padding(.horizontal, wallMargin)
        }
        .frame(width: left + camera + right, height: height)
    }

    /// The shape as it looks on screen, on a light backdrop: the eyebrow over the camera on a display without a notch,
    /// the camera housing on one with.
    static func pill<V: View>(_ content: V, left: CGFloat, right: CGFloat, camera: CGFloat, height: CGFloat,
                              hasNotch: Bool) -> some View {
        let width = left + camera + right
        let shape = NotchShape(topRadius: hasNotch ? 6 : 14, bottomRadius: 14, floating: !hasNotch)
        return ZStack(alignment: .topLeading) {
            shape.fill(Color.black).frame(width: width, height: height)
            if hasNotch {
                Rectangle().fill(Color(white: 0.09)).frame(width: camera - 12, height: height).offset(x: left + 6)
            } else {
                EyebrowMark(lift: 0).frame(width: camera, height: height).offset(x: left)
            }
            content.padding(.horizontal, wallMargin).frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .padding(14)
        .background(Color(white: 0.62))
    }

    /// Measures a `marked` render.
    static func measure(_ rep: NSBitmapImageRep, left: CGFloat, camera: CGFloat) -> Measure {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let width = rep.pixelsWide, height = rep.pixelsHigh
        var contentColumns = [Bool](repeating: false, count: width)
        var cameraHasContent = false
        let cameraRange = Int((left * scale).rounded())..<Int(((left + camera) * scale).rounded())
        // The marker's colour as the display renders it.
        let marker = rep.colorAt(x: cameraRange.lowerBound + 2, y: 1)?.usingColorSpace(.sRGB) ?? .magenta
        let isMarker = { (c: NSColor) in
            max(abs(c.redComponent - marker.redComponent), abs(c.greenComponent - marker.greenComponent),
                abs(c.blueComponent - marker.blueComponent)) < 0.2
        }
        for x in 0..<width {
            for y in 0..<height {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                if cameraRange.contains(x) {
                    if !isMarker(color) { cameraHasContent = true }
                    continue
                }
                if !isMarker(color) && max(r, g, b) > 0.06 {
                    contentColumns[x] = true
                    break
                }
            }
        }
        let columns = contentColumns.enumerated().filter(\.element).map(\.offset)
        let leftColumns = columns.filter { $0 < cameraRange.lowerBound }
        let rightColumns = columns.filter { $0 >= cameraRange.upperBound }
        let wide = CGFloat(width) / scale
        return Measure(
            leftGap: left - CGFloat((leftColumns.last ?? 0) + 1) / scale,
            rightGap: CGFloat(rightColumns.first ?? width) / scale - (left + camera),
            leftMargin: CGFloat(leftColumns.first ?? 0) / scale,
            rightMargin: wide - CGFloat((rightColumns.last ?? width - 1) + 1) / scale,
            intrudes: cameraHasContent)
    }

    static func savePNG(_ rep: NSBitmapImageRep, to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
