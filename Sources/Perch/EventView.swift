import PerchCore
import SwiftUI

/// How an event is laid out.
enum EventLayout {
    /// A strip, placed like the volume indicator.
    case compact(HUDLayout)
    /// A card the island opens into: a large animated icon, a title and a line
    /// below it. `top` is the band hidden by the notch.
    case card(top: CGFloat, scale: CGFloat)
}

/// An event in the island: as a card, or compact with an animated icon on the
/// left and a short value on the right (beside the notch), or a row with a
/// title below it. Each event animates once, as it appears; nothing keeps
/// running afterwards.
struct EventView: View {
    let event: IslandEvent
    let layout: EventLayout

    var body: some View {
        Group {
            switch layout {
            case let .card(top, scale):
                card(top: top, s: scale)
            case let .compact(.beside(wing, height)):
                HStack(spacing: 0) {
                    EventIcon(kind: event.kind)
                        .frame(width: wing - 18, alignment: .leading)
                        .padding(.leading, 18)
                    Spacer(minLength: 0)
                    EventText(text: shortValue, color: valueColor)
                        .frame(width: wing - 18, alignment: .trailing)
                        .padding(.trailing, 18)
                }
                .frame(height: height)
            case let .compact(.below(notchHeight)):
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    row.frame(height: NotchLayout.hudRow).offset(y: -3)
                }
            case let .compact(.plain(height)):
                row.frame(height: height)
            }
        }
        // A new event replays the animations, even of the same kind.
        .id(event.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: event.spokenDescription))
    }

    private var row: some View {
        HStack(spacing: 12) {
            EventIcon(kind: event.kind)
            EventText(text: title, color: .white)
            Spacer(minLength: 8)
            EventText(text: value, color: valueColor)
        }
        .padding(.horizontal, 20)
    }

    /// The card: the icon large on the left, the title and what happened beside
    /// it, sliding in a beat after the island opens; the charge in large figures.
    private func card(top: CGFloat, s: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
            HStack(spacing: 16 * s) {
                EventIcon(kind: event.kind)
                    .environment(\.eventIconScale, 2.1 * s)
                    .frame(width: 60 * s, height: 52 * s)
                VStack(alignment: .leading, spacing: 3 * s) {
                    Text(verbatim: title)
                        .font(.system(size: 16 * s, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: detail)
                        .font(.system(size: 13 * s, weight: .medium))
                        .foregroundStyle(valueColor)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .modifier(SlideIn(distance: 10 * s, delay: 0.12))
                Spacer(minLength: 8 * s)
                if let figure {
                    Text(verbatim: figure)
                        .font(.system(size: 28 * s, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                        .modifier(SlideIn(distance: -10 * s, delay: 0.2))
                }
            }
            .padding(.horizontal, 24 * s)
            .frame(maxHeight: .infinity)
        }
    }

    /// The line under the card's title.
    private var detail: String {
        switch event.kind {
        case .power(.pluggedIn): text("Power adapter connected")
        case .power(.unplugged): text("Power adapter disconnected")
        case .power(.low): text("Connect the charger")
        case .microphone(let app): app.map { String(format: text("Used by %@"), $0) } ?? text("In use")
        default: value
        }
    }

    /// A large figure at the card's right end: the charge.
    private var figure: String? {
        switch event.kind {
        case .power(.pluggedIn(let level)), .power(.unplugged(let level)), .power(.low(let level)): percent(level)
        default: nil
        }
    }

    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    private func percent(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }

    /// The single value beside the notch.
    private var shortValue: String {
        switch event.kind {
        case .focus(let name, let on): on ? name : switchText(false)
        case .power(.pluggedIn(let level)), .power(.unplugged(let level)), .power(.low(let level)): percent(level)
        case .headphones(let name, _, let connected): connected ? name : text("Disconnected")
        case .capsLock(let on): switchText(on)
        case .microphone(let app): app ?? text("Microphone")
        case .camera: text("Camera")
        }
    }

    private var title: String {
        switch event.kind {
        case .focus(let name, _): name
        case .power(.pluggedIn): text("Charging")
        case .power(.unplugged): text("On battery")
        case .power(.low): text("Low battery")
        case .headphones(let name, _, _): name
        case .capsLock: "Caps Lock"
        case .microphone: text("Microphone")
        case .camera: text("Camera")
        }
    }

    private var value: String {
        switch event.kind {
        case .focus(_, let on), .capsLock(let on): switchText(on)
        case .power(.pluggedIn(let level)), .power(.unplugged(let level)), .power(.low(let level)): percent(level)
        case .headphones(_, _, let connected): text(connected ? "Connected" : "Disconnected")
        case .microphone(let app): app ?? text("In use")
        case .camera: text("In use")
        }
    }

    private var valueColor: Color {
        switch event.kind {
        case .focus(let name, let on): on ? FocusLook(name: name).swiftUIColor : .white.opacity(0.55)
        case .power(.pluggedIn): EventColors.charging
        case .power(.unplugged): .white
        case .power(.low): EventColors.low
        case .headphones(_, _, let connected): connected ? .white : .white.opacity(0.55)
        case .capsLock(let on): on ? EventColors.capsLock : .white.opacity(0.55)
        case .microphone: EventColors.microphone
        case .camera: EventColors.camera
        }
    }
}

enum EventColors {
    static let charging = Color(red: 0.2, green: 0.84, blue: 0.4)
    static let low = Color(red: 1, green: 0.27, blue: 0.23)
    static let capsLock = Color(red: 0.2, green: 0.9, blue: 0.45)
    static let microphone = Color(red: 1, green: 0.62, blue: 0.04)
    static let camera = Color(red: 0.19, green: 0.82, blue: 0.35)
}

extension FocusLook {
    var swiftUIColor: Color { Color(red: color.red, green: color.green, blue: color.blue) }
}

private struct EventText: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .transition(.opacity)
    }
}

/// Text that slides a little way in and fades in, a moment after the card opens.
private struct SlideIn: ViewModifier {
    let distance: CGFloat
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: shown || reduceMotion ? 0 : distance)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

// MARK: - Icons

private struct EventIconScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// How big event icons are drawn: 1 beside the notch, larger in the event card.
    var eventIconScale: CGFloat {
        get { self[EventIconScaleKey.self] }
        set { self[EventIconScaleKey.self] = newValue }
    }
}

/// Values the icon animations move through, frame by frame.
private struct Pose {
    var scale = 1.0
    var angle = 0.0
    var lift = 0.0
    var glow = 0.0
    var ring = 0.0
}

private struct EventIcon: View {
    @Environment(\.eventIconScale) private var k
    let kind: IslandEvent.Kind
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        icon
            .frame(width: 26 * k, height: 22 * k)
            .onAppear { shown = true }
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .focus(let name, let on):
            FocusIcon(look: FocusLook(name: name), on: on, play: shown, still: reduceMotion)
        case .power(let change):
            BatteryIcon(change: change, play: shown, still: reduceMotion)
        case .headphones(_, let symbol, let connected):
            HeadphonesIcon(symbol: symbol, connected: connected, play: shown, still: reduceMotion)
        case .capsLock(let on):
            CapsLockIcon(on: on, play: shown, still: reduceMotion)
        case .microphone:
            PulseIcon(symbol: "mic.fill", color: EventColors.microphone, play: shown, still: reduceMotion)
        case .camera:
            PulseIcon(symbol: "video.fill", color: EventColors.camera, play: shown, still: reduceMotion)
        }
    }
}

/// The Focus symbol swings in like a moon rising, in the Focus colour, with a
/// soft glow that fades to a faint halo. Turning off, it dims and is crossed out.
///
/// Every animation here starts from the resting look and jumps to its first
/// pose at once, so whatever SwiftUI shows after the keyframes is the rest.
private struct FocusIcon: View {
    @Environment(\.eventIconScale) private var k
    let look: FocusLook
    let on: Bool
    let play: Bool
    let still: Bool

    var body: some View {
        let color = look.swiftUIColor
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 22 * k, height: 22 * k)
                .blur(radius: 7 * k)
                .keyframeAnimator(initialValue: Pose(glow: on ? 0.3 : 0), trigger: play) { content, pose in
                    content.opacity(still ? (on ? 0.3 : 0) : pose.glow)
                } keyframes: { _ in
                    KeyframeTrack(\.glow) {
                        MoveKeyframe(0)
                        CubicKeyframe(on ? 0.75 : 0, duration: 0.3)
                        CubicKeyframe(on ? 0.3 : 0, duration: 0.7)
                    }
                }
            Image(systemName: look.symbol)
                .font(.system(size: 15 * k, weight: .semibold))
                .foregroundStyle(on ? color : .white.opacity(0.5))
            if !on {
                Capsule()
                    .fill(.white.opacity(0.75))
                    .frame(width: 2 * k, height: 20 * k)
                    .rotationEffect(.degrees(-45))
                    .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
                        content.scaleEffect(x: 1, y: still ? 1 : pose.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.12)
                            SpringKeyframe(1, duration: 0.3, spring: .snappy)
                        }
                    }
            }
        }
        .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
            content
                .scaleEffect(still ? 1 : pose.scale)
                .rotationEffect(.degrees(still ? 0 : pose.angle))
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                if on {
                    MoveKeyframe(0.3)
                    SpringKeyframe(1.18, duration: 0.28, spring: .snappy)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                } else {
                    MoveKeyframe(1)
                    CubicKeyframe(0.86, duration: 0.15)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
            }
            KeyframeTrack(\.angle) {
                MoveKeyframe(on ? -50 : 0)
                SpringKeyframe(on ? 10 : 0, duration: 0.3, spring: .snappy)
                SpringKeyframe(0, duration: 0.4, spring: .bouncy)
            }
        }
    }
}

/// A battery that fills to its level as the charger is plugged in, while a bolt
/// pops onto it. Unplugged, it just shows the level; running low, it is red
/// and gives a shiver.
private struct BatteryIcon: View {
    @Environment(\.eventIconScale) private var k
    let change: PowerChange
    let play: Bool
    let still: Bool

    private var level: Double {
        switch change {
        case .pluggedIn(let level), .unplugged(let level), .low(let level): max(0.04, level)
        }
    }

    private var color: Color {
        switch change {
        case .pluggedIn: EventColors.charging
        case .unplugged: level <= 0.2 ? EventColors.low : .white
        case .low: EventColors.low
        }
    }

    private var charging: Bool {
        if case .pluggedIn = change { return true }
        return false
    }

    private var low: Bool {
        if case .low = change { return true }
        return false
    }

    var body: some View {
        let k = k
        let width: CGFloat = 25 * k, height: CGFloat = 12 * k
        let level = level, charging = charging, low = low
        HStack(spacing: 1.5 * k) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5 * k, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1 * k)
                RoundedRectangle(cornerRadius: 2 * k, style: .continuous)
                    .fill(color)
                    .keyframeAnimator(initialValue: Pose(scale: level), trigger: play) { content, pose in
                        content.frame(width: max(1, (width - 4 * k) * (still ? level : pose.scale)), height: height - 4 * k)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(charging ? 0 : level)
                            LinearKeyframe(charging ? 0 : level, duration: 0.1)
                            CubicKeyframe(level, duration: charging ? 0.7 : 0.1)
                        }
                    }
                    .padding(.leading, 2 * k)
            }
            .frame(width: width, height: height)
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 1.5 * k, height: 4 * k)
        }
        .overlay {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10 * k, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1 * k)
                    .offset(x: -1 * k)
                    .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
                        content.scaleEffect(still ? 1 : pose.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.25)
                            SpringKeyframe(1.45, duration: 0.18, spring: .snappy)
                            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                        }
                    }
            }
        }
        .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
            content.rotationEffect(.degrees(still ? 0 : pose.angle))
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                MoveKeyframe(0)
                if low {
                    CubicKeyframe(7, duration: 0.07)
                    CubicKeyframe(-6, duration: 0.07)
                    CubicKeyframe(5, duration: 0.07)
                    CubicKeyframe(-3, duration: 0.07)
                    CubicKeyframe(0, duration: 0.07)
                } else {
                    LinearKeyframe(0, duration: 0.1)
                }
            }
        }
    }
}

/// Headphones pop in while a ring draws itself around them and fades; leaving, they dim.
private struct HeadphonesIcon: View {
    @Environment(\.eventIconScale) private var k
    let symbol: String
    let connected: Bool
    let play: Bool
    let still: Bool

    var body: some View {
        let k = k
        ZStack {
            if connected {
                Circle()
                    .stroke(EventColors.charging, style: StrokeStyle(lineWidth: 1.8 * k, lineCap: .round))
                    .frame(width: 24 * k, height: 24 * k)
                    .keyframeAnimator(initialValue: Pose(glow: 0, ring: 1), trigger: play) { content, pose in
                        content
                            .mask {
                                Circle()
                                    .trim(from: 0, to: pose.ring)
                                    .stroke(style: StrokeStyle(lineWidth: 4 * k, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .opacity(still ? 0 : pose.glow)
                    } keyframes: { _ in
                        KeyframeTrack(\.ring) {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.1)
                            CubicKeyframe(1, duration: 0.6)
                        }
                        KeyframeTrack(\.glow) {
                            MoveKeyframe(1)
                            LinearKeyframe(1, duration: 0.8)
                            CubicKeyframe(0, duration: 0.5)
                        }
                    }
            }
            Image(systemName: symbol)
                .font(.system(size: 13 * k, weight: .semibold))
                .foregroundStyle(connected ? .white : .white.opacity(0.5))
        }
        .keyframeAnimator(initialValue: Pose(scale: connected ? 1 : 0.95), trigger: play) { content, pose in
            content.scaleEffect(still ? 1 : pose.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                if connected {
                    MoveKeyframe(0.4)
                    SpringKeyframe(1.15, duration: 0.25, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                } else {
                    MoveKeyframe(1)
                    CubicKeyframe(0.82, duration: 0.2)
                    SpringKeyframe(0.95, duration: 0.3, spring: .smooth)
                }
            }
        }
    }
}

/// The Caps Lock key is pressed and its light comes on, or goes off.
private struct CapsLockIcon: View {
    @Environment(\.eventIconScale) private var k
    let on: Bool
    let play: Bool
    let still: Bool

    var body: some View {
        let k = k
        ZStack(alignment: .topTrailing) {
            Image(systemName: on ? "capslock.fill" : "capslock")
                .font(.system(size: 15 * k, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.5))
                .padding(3 * k)
            Circle()
                .fill(on ? EventColors.capsLock : .white.opacity(0.25))
                .frame(width: 5 * k, height: 5 * k)
                .shadow(color: on ? EventColors.capsLock : .clear, radius: 3 * k)
                .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
                    content.scaleEffect(still ? 1 : pose.scale)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        if on {
                            MoveKeyframe(0)
                            LinearKeyframe(0, duration: 0.15)
                            SpringKeyframe(1.6, duration: 0.15, spring: .snappy)
                            SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                        } else {
                            MoveKeyframe(1)
                            CubicKeyframe(0.6, duration: 0.2)
                            SpringKeyframe(1, duration: 0.3, spring: .smooth)
                        }
                    }
                }
        }
        .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
            content.offset(y: still ? 0 : pose.lift * k).scaleEffect(still ? 1 : pose.scale)
        } keyframes: { _ in
            KeyframeTrack(\.lift) {
                MoveKeyframe(0)
                CubicKeyframe(2.5, duration: 0.09)
                SpringKeyframe(0, duration: 0.35, spring: .bouncy)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(1)
                CubicKeyframe(0.9, duration: 0.09)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
        }
    }
}

/// Microphone or camera: the symbol pops in and sends out one ripple.
private struct PulseIcon: View {
    @Environment(\.eventIconScale) private var k
    let symbol: String
    let color: Color
    let play: Bool
    let still: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5 * k)
                .frame(width: 18 * k, height: 18 * k)
                .keyframeAnimator(initialValue: Pose(scale: 1.9, glow: 0), trigger: play) { content, pose in
                    content.scaleEffect(pose.scale).opacity(still ? 0 : pose.glow)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(0.8)
                        LinearKeyframe(0.8, duration: 0.15)
                        CubicKeyframe(1.9, duration: 0.7)
                    }
                    KeyframeTrack(\.glow) {
                        MoveKeyframe(0)
                        LinearKeyframe(0, duration: 0.15)
                        LinearKeyframe(0.8, duration: 0.05)
                        CubicKeyframe(0, duration: 0.65)
                    }
                }
            Image(systemName: symbol)
                .font(.system(size: 13 * k, weight: .semibold))
                .foregroundStyle(color)
        }
        .keyframeAnimator(initialValue: Pose(), trigger: play) { content, pose in
            content.scaleEffect(still ? 1 : pose.scale)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(0.4)
                SpringKeyframe(1.15, duration: 0.22, spring: .snappy)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
        }
    }
}

/// The dot that stays on the island while the microphone (orange) or a camera
/// (green) is in use, as on iPhone. It pops in once; it does not pulse, so it
/// costs nothing while it shows.
struct PrivacyDot: View {
    let use: PrivacyUse
    @State private var shown = false

    var body: some View {
        let color = use.camera ? EventColors.camera : EventColors.microphone
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.8), radius: 3)
            .keyframeAnimator(initialValue: Pose(), trigger: shown) { content, pose in
                content.scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0)
                    SpringKeyframe(1.6, duration: 0.2, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
            }
            .onAppear { shown = true }
            .accessibilityLabel(Text(use.camera ? "Camera in use" : "Microphone in use"))
    }
}
