import AppKit
import IOKit

struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var collapsedSize: CGSize
    var hasNotch: Bool

    /// Without a camera housing the eyebrow floats this far below the top edge and stays inside the menu bar.
    var topInset: CGFloat { hasNotch ? 0 : 3 }

    /// True while a MacBook's lid is closed (clamshell mode with an external display).
    static var lidIsClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// The display named in settings if it is connected; otherwise the one with the pointer, then the built-in display
    /// with a camera housing, then the main screen.
    static func pickScreen(preferredName: String = "", pointer: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.map { screen in
            ScreenCandidate(name: screen.localizedName, hasNotch: screen.safeAreaInsets.top > 0, isMain: screen == NSScreen.main,
                            hasPointer: holdsPointer(screen.frame, pointer),
                            isBuiltin: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                                .map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        }
        return pick(candidates, preferredName: preferredName, lidClosed: lidIsClosed).map { screens[$0] }
    }

    /// Whether the pointer is on the screen with this frame. At the very top the pointer sits on the frame's top edge, which
    /// `contains` leaves out.
    static func holdsPointer(_ frame: NSRect, _ point: NSPoint) -> Bool { NSMouseInRect(point, frame, false) }

    /// Whether the pointer is off the notch's screen and on another one; on no screen at all, it has not left.
    static func pointerLeft(_ current: NSRect, for point: NSPoint, among screens: [NSRect]) -> Bool {
        !holdsPointer(current, point) && screens.contains { holdsPointer($0, point) }
    }

    struct ScreenCandidate: Equatable {
        var name: String
        var hasNotch: Bool
        var isMain: Bool
        var hasPointer = false
        var isBuiltin: Bool
    }

    /// The index of the screen to use. With the lid closed the built-in display is passed over: it can stay listed, camera housing
    /// and all, for a moment after the lid closes.
    static func pick(_ screens: [ScreenCandidate], preferredName: String, lidClosed: Bool) -> Int? {
        let usable = screens.indices.filter { !(lidClosed && screens[$0].isBuiltin) }
        if !preferredName.isEmpty, let match = usable.first(where: { screens[$0].name == preferredName }) { return match }
        return usable.first { screens[$0].hasPointer } ?? usable.first { screens[$0].hasNotch } ?? usable.first { screens[$0].isMain }
            ?? usable.first ?? screens.indices.first
    }

    /// Width of the collapsed eyebrow on a display without a camera housing.
    static let browWidth: CGFloat = 44

    /// Used only when no screen is attached at launch; the next screen change relayouts.
    init() {
        screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        collapsedSize = CGSize(width: Self.browWidth, height: 18)
        hasNotch = false
    }

    /// Debug builds can pretend a display has a notch of this width with `--fake-notch <points>`.
    private static let fakeNotchWidth: CGFloat = {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--fake-notch"), i + 1 < CommandLine.arguments.count,
           let width = Double(CommandLine.arguments[i + 1]) { return width }
        #endif
        return 0
    }()

    init(screen: NSScreen) {
        screenFrame = screen.frame
        (collapsedSize, hasNotch) = Self.collapsedSize(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
            leftAuxWidth: screen.auxiliaryTopLeftArea?.width, rightAuxWidth: screen.auxiliaryTopRightArea?.width,
            fakeNotchWidth: Self.fakeNotchWidth)
    }

    /// The closed shape's size for a display, and whether it has a camera housing.
    static func collapsedSize(frame: NSRect, visibleFrame: NSRect, safeTop: CGFloat, leftAuxWidth: CGFloat?,
                              rightAuxWidth: CGFloat?, fakeNotchWidth: CGFloat) -> (size: CGSize, hasNotch: Bool) {
        if safeTop > 0, let leftAuxWidth, let rightAuxWidth {
            // The shape's top corners flare outward, so widen it to keep the body as wide as the housing.
            return (CGSize(width: frame.width - leftAuxWidth - rightAuxWidth + 12, height: safeTop), true)
        } else if fakeNotchWidth > 0 {
            return (CGSize(width: fakeNotchWidth, height: 32), true)
        } else {
            let menuBarHeight = frame.maxY - visibleFrame.maxY
            return (CGSize(width: browWidth, height: max((menuBarHeight > 0 ? menuBarHeight : 24) - 6, 16)), false)
        }
    }

    /// Widest the expanded shape may grow to fit every tab.
    var maxExpandedWidth: CGFloat { max(AppSettings.expandedWidthRange.upperBound, min(screenFrame.width - 80, 1200)) }

    /// The panel is sized for the largest allowed shape; only the drawn shape changes.
    var panelFrame: NSRect {
        let size = CGSize(width: maxExpandedWidth + 40,
                          height: AppSettings.expandedHeightRange.upperBound + 20)
        return NSRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The expanded shape sits against the top edge even where the collapsed eyebrow floats, so it passes `inset: 0`.
    func shapeRect(size: CGSize, inset: CGFloat? = nil) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2,
               y: screenFrame.maxY - (inset ?? topInset) - size.height,
               width: size.width, height: size.height)
    }
}
