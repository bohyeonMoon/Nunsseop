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

    /// The display named in settings if it is connected; otherwise the built-in display
    /// with a camera housing, then the main screen.
    static func pickScreen(preferredName: String = "") -> NSScreen? {
        if !preferredName.isEmpty, let match = NSScreen.screens.first(where: { $0.localizedName == preferredName }) {
            return match
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
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
