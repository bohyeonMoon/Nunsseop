import SwiftUI

/// The eyebrow's face for what the agents and the AI limits are doing. Waiting and focused last as long as the agents
/// stay so; happy, tired and relieved mark a moment and then give way to them again.
enum BrowMood: String, CaseIterable {
    case rest, waiting, focused, happy, tired, relieved

    /// How far the stroke moves from rest on `EyebrowArch`'s 100 × 40 grid.
    var pose: BrowPose {
        switch self {
        case .rest: BrowPose()
        case .waiting: BrowPose(lift: 5, tilt: 7, arch: 11)
        case .focused: BrowPose(lift: -3, tilt: 9, arch: -7)
        case .happy: BrowPose(lift: 6, tilt: -1, arch: 14)
        case .tired: BrowPose(lift: -2, tilt: -10, arch: 3)
        case .relieved: BrowPose(lift: 3, tilt: -4, arch: 7)
        }
    }

    /// How long a mood that marks a moment shows; nil for the ones that follow the agents.
    var lasts: TimeInterval? {
        switch self {
        case .rest, .waiting, .focused: nil
        case .happy: 2.6
        case .tired: 4
        case .relieved: 3
        }
    }

    /// The name a notice carries in place of an SF Symbol to show the eyebrow in this mood.
    var symbol: String { "brow.\(rawValue)" }

    init?(symbol: String) {
        guard symbol.hasPrefix("brow.") else { return nil }
        self.init(rawValue: String(symbol.dropFirst(5)))
    }

    /// One agent asking for you outweighs any number at work.
    static func steady(asking: Bool, working: Bool) -> BrowMood {
        asking ? .waiting : working ? .focused : .rest
    }

    static func steady(_ entries: [AgentBoard.Entry]) -> BrowMood {
        steady(asking: entries.contains { $0.agent.state == .waiting && !$0.agent.finished },
               working: entries.contains { $0.agent.state == .working })
    }
}

/// The stroke moved up (`lift`), turned so its tail rises over its head (`tilt`), and bent up in the middle (`arch`).
struct BrowPose: Equatable {
    var lift: CGFloat = 0
    var tilt: CGFloat = 0
    var arch: CGFloat = 0

    /// How far a point of the stroke at `x` (0 at the head, 100 at the tail) moves up.
    func rise(at x: CGFloat) -> CGFloat {
        lift + tilt * (x - 50) / 50 + arch * sin(.pi * x / 100)
    }

    /// How far the stroke moves up on average, which an icon takes back so the face sits in the middle of its slot.
    var meanRise: CGFloat { lift + arch * 2 / .pi }
}

/// Which agents just finished a turn, for the eyebrow's cheer: a session seen working that now waits because its turn ended.
struct FinishWatch {
    private var working: Set<String> = []

    mutating func step(_ entries: [AgentBoard.Entry]) -> [AgentBoard.Entry] {
        let finished = entries.filter { working.contains($0.key) && $0.agent.state == .waiting && $0.agent.finished }
        working = Set(entries.filter { $0.agent.state == .working }.map(\.key))
        return finished
    }
}

/// The eyebrow drawn as an icon in a mood, `width` wide; a happy one hops twice when it appears.
struct BrowGlyph: View {
    let mood: BrowMood
    let width: CGFloat
    @State private var hops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EyebrowArch(lift: 0, pose: mood.pose)
            .fill(EyebrowMark.color)
            .frame(width: width, height: width * 0.42)
            .offset(y: mood.pose.meanRise * width / 100)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: hops) { content, rise in
                content.offset(y: -rise * width / 10)
            } keyframes: { _ in
                BrowGlyph.hop
            }
            .modifier(BrowTwitch(active: mood == .waiting))
            .onAppear { if mood == .happy && !reduceMotion { hops += 1 } }
            .accessibilityHidden(true)
    }

    /// Up, down, up, down, in tenths of the eyebrow's width.
    static var hop: KeyframeTrack<CGFloat, CGFloat, some KeyframeTrackContent<CGFloat>> {
        KeyframeTrack {
            SpringKeyframe(1.2, duration: 0.15)
            SpringKeyframe(0, duration: 0.15)
            SpringKeyframe(1, duration: 0.15)
            SpringKeyframe(0, duration: 0.2)
        }
    }
}

/// Every few seconds a waiting eyebrow flicks its tail, as if asking again. Still under Reduce Motion.
struct BrowTwitch: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let every: TimeInterval = 4

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.periodic(from: .now, by: Self.every)) { context in
                content.keyframeAnimator(initialValue: 0.0, trigger: context.date) { view, angle in
                    view.rotationEffect(.degrees(angle), anchor: .leading)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-8, duration: 0.12)
                        CubicKeyframe(0, duration: 0.18)
                        CubicKeyframe(-5, duration: 0.1)
                        CubicKeyframe(0, duration: 0.15)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// A notice's icon: the eyebrow for a `brow.` name, otherwise the SF Symbol in the caller's font.
struct NoticeGlyph: View {
    let name: String
    /// The eyebrow's width; an SF Symbol sizes by the font instead.
    let browWidth: CGFloat

    var body: some View {
        if let mood = BrowMood(symbol: name) {
            BrowGlyph(mood: mood, width: browWidth)
        } else {
            Image(systemName: name)
        }
    }
}
