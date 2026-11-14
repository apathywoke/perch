import AppKit
import PerchCore
import SwiftUI

/// The island outline: flat against the top screen edge, concave "ears" at the
/// top corners and rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2)
        let b = min(bottomRadius, rect.height - t, (rect.width - 2 * t) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: MediaService
    @AppStorage(Pref.scale) private var scale = 1.0
    @AppStorage(Pref.shadow) private var shadow = true
    @AppStorage(Pref.hudStyle) private var hudStyle = HUDStyle.beside
    @AppStorage(Pref.swapSides) private var swapSides = false
    @AppStorage(Pref.visualizer) private var visualizer = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = scale
        let notch = model.notchSize
        let expanded = model.phase == .expanded
        let hud = expanded ? nil : model.hud
        let card = model.phase == .peek && hud == nil && model.active
        let tall = hud != nil && model.hasNotch && hudStyle == .below
        let swell = model.hovering && !reduceMotion && model.phase == .collapsed && hud == nil
        let size = NotchLayout.size(phase: model.phase, notch: notch, hasNotch: model.hasNotch, active: model.active,
                                    scale: s, hud: model.hud == nil ? nil : hudStyle, swell: swell)
        let player = NotchLayout.player(notch: notch, hasNotch: model.hasNotch, scale: s)
        let collapsed = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: model.hasNotch,
                                         active: model.active, scale: s)
        let ear: CGFloat = expanded ? 20 : ((card || tall) ? 10 : NotchLayout.earRadius)
        let bottom: CGFloat = expanded ? 32 * s : ((card || tall) ? 24 : (swell ? 14 : 10))
        let shape = NotchShape(topRadius: ear, bottomRadius: bottom)

        // Artwork and visualizer are single views that travel between the
        // collapsed island, the track card and the open player.
        let showMedia = hud == nil && (expanded ? media.track != nil : model.active)
        let side: CGFloat = swapSides ? 1 : -1
        let wingCenter = notch.width / 2 + (size.width - notch.width) / 4
        let smallArt = (notch.height * 0.56).rounded() * (swell ? 1.1 : 1)
        let art: CGFloat = expanded ? player.art : (card ? NotchLayout.peekArtwork : smallArt)
        let artX: CGFloat = expanded ? -player.width / 2 + player.inset + art / 2
            : (card ? side * (size.width / 2 - NotchLayout.peekSide / 2) : side * wingCenter)
        let artY: CGFloat = expanded ? player.artTop : (size.height - art) / 2
        let barsScale = (expanded ? 14 * s : (card ? 17 : smallArt * 0.62)) / VisualizerView.baseHeight
        let barsX: CGFloat = expanded
            ? player.width / 2 - player.inset - 4 * s - VisualizerView.baseWidth * barsScale / 2
            : (card ? -side * (size.width / 2 - NotchLayout.peekSide / 2) : -side * wingCenter)
        let barsY = (expanded ? player.artTop + player.art / 2 : size.height / 2) - VisualizerView.baseHeight / 2

        // The open player's content grows from the collapsed island's proportions.
        let growFrom = CGSize(width: min(1, collapsed.width / player.width),
                              height: min(1, collapsed.height / player.height))

        ZStack(alignment: .top) {
            shape.fill(.black)
                .shadow(color: .black.opacity(expanded && shadow ? 0.38 : 0), radius: 22, y: 10)

            ZStack(alignment: .top) {
                if expanded {
                    ExpandedView(model: model, media: media, metrics: player, scale: s)
                        .frame(width: player.width, height: player.height)
                        .transition(morphTransition(from: growFrom))
                } else if let hud {
                    HUDView(state: hud, layout: hudLayout(notch: notch), tint: media.tint)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(contentTransition(from: 0.9))
                } else if card, let track = media.track {
                    PeekView(track: track)
                        .padding(.top, notch.height)
                        .padding(.horizontal, NotchLayout.peekSide)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(contentTransition(from: 0.9))
                }

                // While the player is open, the indicator gets its own row at the bottom.
                if expanded, let state = model.hud {
                    HUDView(state: state, layout: .plain(height: player.hudRow), tint: media.tint)
                        .frame(width: player.width, height: player.hudRow)
                        .offset(y: player.height - 10 * s)
                        .transition(contentTransition(from: 0.9))
                }

                ArtworkView(image: media.artwork, size: art, radius: art * (expanded ? 0.2 : 0.24))
                    .onTapGesture {
                        expanded ? media.openSourceApp() : NotchController.shared.collapsedClicked()
                    }
                    .modifier(TravelBlur(progress: expanded ? 1 : 0, radius: reduceMotion ? 0 : 7))
                    .scaleEffect(showMedia ? 1 : 0.4)
                    .opacity(showMedia ? 1 : 0)
                    .offset(x: artX, y: artY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(media.sourceName.map { Text("Open \($0)") } ?? Text("Artwork"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!expanded || !showMedia)

                VisualizerView(playing: media.track?.isPlaying == true, tint: media.tint)
                    .modifier(TravelBlur(progress: expanded ? 1 : 0, radius: reduceMotion ? 0 : 4))
                    .scaleEffect(showMedia && visualizer ? barsScale : 0.3)
                    .opacity(showMedia && visualizer ? 1 : 0)
                    .offset(x: barsX, y: barsY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(topRadius: 0, bottomRadius: bottom))
        }
        .frame(width: size.width + ear * 2, height: size.height)
        .contentShape(shape)
        .onTapGesture {
            if !expanded { NotchController.shared.collapsedClicked() }
        }
        .contextMenu {
            Button("Settings…") { AppDelegate.shared?.showSettings() }
            Divider()
            Button("Quit Perch") { NSApp.terminate(nil) }
        }
        // VoiceOver: collapsed, the island is one button that says what plays and
        // opens the player; expanded, its controls are reachable one by one.
        .accessibilityElement(children: expanded ? .contain : .ignore)
        .accessibilityLabel(Text(verbatim: "Perch"))
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(expanded ? Text(verbatim: "") : Text("Opens the player"))
        .accessibilityAddTraits(expanded ? [] : .isButton)
        .accessibilityAction { NotchController.shared.toggle() }
        .accessibilityAction(named: Text("Play / pause")) { media.togglePlayPause() }
        .accessibilityAction(named: Text("Next track")) { media.next() }
        .accessibilityAction(named: Text("Previous track")) { media.previous() }
        .opacity(model.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func hudLayout(notch: CGSize) -> HUDLayout {
        guard model.hasNotch else { return .plain(height: notch.height) }
        return hudStyle == .beside ? .beside(wing: NotchLayout.hudWing, height: notch.height)
                                   : .below(notchHeight: notch.height)
    }

    /// The open player morphs out of the island: its content stays in place,
    /// heavily blurred, and grows with the shape on the same spring, coming
    /// into focus as the shape settles. Closing runs the same path backwards.
    /// With "Reduce motion" it only fades.
    private func morphTransition(from start: CGSize) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(Motion.contentIn),
                               removal: .opacity.animation(Motion.contentOut))
        }
        return .modifier(active: Morph(progress: 0, from: start), identity: Morph(progress: 1, from: start))
    }

    /// Smaller content (indicator, track card): grows in from slightly smaller
    /// and blurred, leaves quickly.
    private func contentTransition(from start: CGFloat) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(Motion.contentIn),
                               removal: .opacity.animation(Motion.contentOut))
        }
        return .asymmetric(insertion: .blurFade(scale: start).animation(Motion.contentIn),
                           removal: .blurFade(scale: max(start, 0.94)).animation(Motion.contentOut))
    }

    private var accessibilitySummary: Text {
        if let hud = model.hud { return Text(verbatim: hud.spokenDescription) }
        guard let track = media.track else { return Text("Nothing is playing") }
        let name = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
        return track.isPlaying ? Text("Playing: \(name)") : Text("Paused: \(name)")
    }
}

// MARK: - Motion helpers

/// Drives the open player's content from the island's progress (0 closed, 1 open).
private struct Morph: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1.04) // the opening spring overshoots a touch
        content
            .scaleEffect(x: from.width + (1 - from.width) * p, y: from.height + (1 - from.height) * p, anchor: .top)
            .blur(radius: 14 * max(0, 1 - p))
            .opacity(Double(min(1, max(0, (p - 0.1) / 0.45))))
    }
}

/// Blur that peaks halfway through a move and is gone at both ends.
private struct TravelBlur: ViewModifier, Animatable {
    var progress: CGFloat
    let radius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.blur(radius: radius * sin(.pi * min(max(progress, 0), 1)))
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? scale : 1, anchor: .top)
            .blur(radius: active ? 8 : 0)
            .opacity(active ? 0 : 1)
    }
}

/// Half of a card flip around the vertical axis.
private struct Flip: ViewModifier {
    let angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .opacity(abs(angle) >= 90 ? 0 : 1)
    }
}

private extension AnyTransition {
    static func blurFade(scale: CGFloat) -> AnyTransition {
        .modifier(active: BlurFade(active: true, scale: scale), identity: BlurFade(active: false, scale: scale))
    }

    /// The old artwork turns away, then the new one turns in.
    static var flip: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Flip(angle: -90), identity: Flip(angle: 0))
                .animation(.easeOut(duration: 0.22).delay(0.15)),
            removal: .modifier(active: Flip(angle: 90), identity: Flip(angle: 0))
                .animation(.easeIn(duration: 0.15))
        )
    }
}

/// Track name shown for a moment under the notch when the song changes.
private struct PeekView: View {
    let track: Track

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: track.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if !track.artist.isEmpty {
                Text(verbatim: track.artist)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: NotchLayout.peekRow, alignment: .top)
    }
}

// MARK: - Volume / brightness indicator

private enum HUDLayout {
    /// Icon in the left wing, level in the right wing, nothing under the notch.
    case beside(wing: CGFloat, height: CGFloat)
    /// A row below the notch.
    case below(notchHeight: CGFloat)
    /// A plain row: displays without a notch, and the open player.
    case plain(height: CGFloat)
}

private struct HUDView: View {
    let state: HUDState
    let layout: HUDLayout
    let tint: Color
    @AppStorage(Pref.hudPercent) private var showPercent = true
    @AppStorage(Pref.hudColor) private var colorMode = VisualizerColor.white

    private var level: Double { state.level }

    var body: some View {
        Group {
            switch layout {
            case let .beside(wing, height):
                HStack(spacing: 0) {
                    icon.frame(width: wing - 18, alignment: .leading).padding(.leading, 18)
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        bar
                        if showPercent { percent }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: wing)
                }
                .frame(height: height)
            case let .below(notchHeight):
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    row.frame(height: NotchLayout.hudRow).offset(y: -3)
                }
            case let .plain(height):
                row.frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: state.spokenDescription))
    }

    private var row: some View {
        HStack(spacing: 12) {
            icon
            bar
            if showPercent { percent }
        }
        .padding(.horizontal, 20)
    }

    private var icon: some View {
        Group {
            switch state.kind {
            case .volume:
                if level <= 0.001 {
                    Image(systemName: "speaker.slash.fill")
                } else {
                    Image(systemName: "speaker.wave.3.fill", variableValue: level)
                }
            case .brightness:
                Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 24, alignment: .leading)
    }

    private var bar: some View {
        let color: Color = switch colorMode {
        case .artwork: tint
        case .white: .white
        case .accent: .accentColor
        }
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: max(level > 0.001 ? 6 : 0, proxy.size.width * level))
            }
        }
        .frame(height: 6)
        .frame(minWidth: 30)
    }

    private var percent: some View {
        Text(verbatim: "\(Int((level * 100).rounded()))")
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .contentTransition(.numericText(value: level))
            .frame(width: 24, alignment: .trailing)
    }
}

// MARK: - Expanded

private struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: MediaService
    @ObservedObject private var outputs = AudioOutputs.shared
    let metrics: NotchLayout.PlayerMetrics
    let scale: CGFloat
    @AppStorage(Pref.artworkGlow) private var glow = true
    @AppStorage(Pref.showAlbum) private var showAlbum = false
    @AppStorage(Pref.visualizer) private var visualizer = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let m = metrics, s = scale
        let band = model.hasNotch ? model.notchSize.height : 0

        ZStack(alignment: .topLeading) {
            if glow, media.track != nil {
                RadialGradient(colors: [media.tint.opacity(0.2), media.tint.opacity(0.07), .clear],
                               center: .init(x: 0.14, y: 0.35), startRadius: 0, endRadius: 300 * s)
                    .mask(alignment: .top) {
                        // Fade in below the notch so the strip beside the camera stays pure black.
                        VStack(spacing: 0) {
                            Color.clear.frame(height: band)
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 46 * s)
                            Color.black
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let track = media.track {
                // The artwork itself is drawn by IslandView so it can travel from the collapsed island.
                ZStack(alignment: .topLeading) {
                    titleBlock(track, s: s)
                        .id(track.id)
                        .transition(textTransition)
                }
                .frame(width: m.width - m.textLeading - m.inset - (visualizer ? 34 * s : 0), alignment: .leading)
                .animation(Motion.textIn, value: track.id)
                .offset(x: m.textLeading, y: m.textTop)

                ScrubberView(track: track, tint: media.tint, scale: s) { media.seek(to: $0) }
                    .frame(width: m.width - 2 * (m.inset + 2 * s), height: 16 * s)
                    .offset(x: m.inset + 2 * s, y: m.scrubberCenter - 8 * s)

                controls(track, m: m, s: s)
                    .frame(width: m.width, height: 40 * s)
                    .offset(y: m.controlsCenter - 20 * s)
            } else {
                VStack(spacing: 8 * s) {
                    Image(systemName: "music.note")
                        .font(.system(size: 22 * s, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Nothing is playing")
                        .font(.system(size: 13 * s, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: m.width, height: m.height)
                .padding(.top, band / 2)
            }
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
    }

    private func titleBlock(_ track: Track, s: CGFloat) -> some View {
        let subtitle = [track.artist, showAlbum ? track.album : ""].filter { !$0.isEmpty }.joined(separator: " — ")
        return VStack(alignment: .leading, spacing: 1 * s) {
            Text(verbatim: track.title)
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundStyle(.white)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.system(size: 13 * s))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// The old title blurs away, then the new one comes into focus.
    private var textTransition: AnyTransition {
        let swap = AnyTransition.modifier(active: BlurFade(active: true, scale: 1), identity: BlurFade(active: false, scale: 1))
        let fade = reduceMotion ? AnyTransition.opacity : swap
        return .asymmetric(insertion: fade.animation(Motion.textIn), removal: fade.animation(Motion.textOut))
    }

    /// Five evenly spaced slots: the music app, previous, play / pause, next, sound output.
    private func controls(_ track: Track, m: NotchLayout.PlayerMetrics, s: CGFloat) -> some View {
        let buttonWidth = 46 * s, buttonHeight = 36 * s
        return HStack(spacing: 0) {
            Group {
                if let icon = media.sourceIcon, let name = media.sourceName {
                    ControlButton(width: buttonWidth, height: buttonHeight, label: "Open \(name)",
                                  action: { media.openSourceApp() }) {
                        Image(nsImage: icon).resizable().frame(width: 19 * s, height: 19 * s).opacity(0.9)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: m.controlSpacing)

            ControlButton(width: buttonWidth, height: buttonHeight, label: "Previous track",
                          action: { media.previous() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 19 * s, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: m.controlSpacing)

            ControlButton(width: buttonWidth, height: buttonHeight, label: track.isPlaying ? "Pause" : "Play",
                          action: { media.togglePlayPause() }) {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24 * s, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: m.controlSpacing)

            ControlButton(width: buttonWidth, height: buttonHeight, label: "Next track",
                          action: { media.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 19 * s, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: m.controlSpacing)

            ControlButton(width: buttonWidth, height: buttonHeight, label: "Audio output",
                          action: { NotchController.shared.holdOpen { outputs.showMenu() } }) {
                Image(systemName: outputs.symbol)
                    .font(.system(size: 15 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: m.controlSpacing)
        }
    }
}

// MARK: - Pieces

/// Artwork with a card flip when the image changes.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let key = image.map(ObjectIdentifier.init)
        ZStack {
            face
                .id(key)
                .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.25)) : .flip)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.3), value: key)
    }

    private var face: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.12))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Animated bars. They are decorative: Perch never listens to the audio itself.
/// The bars are Core Animation layers, so the animation runs in the system
/// compositor and costs the app no CPU while music plays.
struct VisualizerView: View {
    let playing: Bool
    let tint: Color
    @AppStorage(Pref.visualizerColor) private var colorMode = VisualizerColor.artwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let baseHeight: CGFloat = 16
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2.25
    static let baseWidth = barWidth * CGFloat(BarsView.count) + spacing * CGFloat(BarsView.count - 1)

    var body: some View {
        let color: NSColor = switch colorMode {
        case .artwork: NSColor(tint)
        case .white: .white
        case .accent: .controlAccentColor
        }
        BarsRepresentable(playing: playing, animated: !reduceMotion, color: color,
                          barWidth: Self.barWidth, spacing: Self.spacing)
            .frame(width: Self.baseWidth, height: Self.baseHeight)
    }
}

struct BarsRepresentable: NSViewRepresentable {
    let playing: Bool
    let animated: Bool
    let color: NSColor
    let barWidth: CGFloat
    let spacing: CGFloat

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.configure(playing: playing, animated: animated, color: color, barWidth: barWidth, spacing: spacing)
    }
}

final class BarsView: NSView {
    static let count = 5
    /// Resting heights while playing with "Reduce motion" on: still reads as music.
    private static let stillLevels: [CGFloat] = [0.55, 0.85, 0.45, 0.75, 0.6]

    private let bars: [CALayer] = (0..<BarsView.count).map { _ in CALayer() }
    private var playing = false
    private var animated = true
    private var barWidth: CGFloat = 3
    private var spacing: CGFloat = 2
    private var animatedHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(playing: Bool, animated: Bool, color: NSColor, barWidth: CGFloat, spacing: CGFloat) {
        let restart = playing != self.playing || animated != self.animated
        self.playing = playing
        self.animated = animated
        self.barWidth = barWidth
        self.spacing = spacing
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        if restart { animatedHeight = 0 }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animatedHeight = 0 // animations are dropped when a layer leaves its window
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let bouncing = playing && animated
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.cornerRadius = barWidth / 2
            bar.position = CGPoint(x: CGFloat(index) * (barWidth + spacing) + barWidth / 2, y: height / 2)
            if bar.bounds.width != barWidth || !bouncing {
                let level = playing ? Self.stillLevels[index] : 0.2
                bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: max(barWidth, height * level))
            }
        }
        CATransaction.commit()

        guard window != nil, height > 0 else { return }
        if !bouncing {
            bars.forEach { $0.removeAnimation(forKey: "bounce") }
        } else if animatedHeight != height {
            animatedHeight = height
            for bar in bars {
                let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
                var values = (0..<7).map { _ in max(barWidth, height * CGFloat.random(in: 0.25...1)) }
                values.append(values[0]) // loop seamlessly
                animation.values = values
                animation.duration = Double.random(in: 1.5...2.3)
                animation.calculationMode = .cubic
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                bar.add(animation, forKey: "bounce")
            }
        }
    }
}

/// Progress bar and time labels. Drawn with Core Animation layers: the bar
/// glides in the compositor and only the two labels change once a second, so
/// an open player costs next to nothing.
private struct ScrubberView: NSViewRepresentable {
    let track: Track
    let tint: Color
    let scale: CGFloat
    let seek: (Double) -> Void
    @AppStorage(Pref.timeStyle) private var timeStyle = TimeStyle.remaining

    func makeNSView(context: Context) -> ScrubberNSView { ScrubberNSView() }

    func updateNSView(_ view: ScrubberNSView, context: Context) {
        view.seek = seek
        view.configure(track: track, scale: scale, showRemaining: timeStyle == .remaining)
    }
}

final class ScrubberNSView: NSView {
    var seek: ((Double) -> Void)?
    private var track: Track?
    private var scale: CGFloat = 1
    private var showRemaining = true
    private var dragFraction: CGFloat?
    private var hovering = false
    private var timer: Timer?

    private let rail = CALayer()
    private let fill = CALayer()
    private let leftLabel = CATextLayer()
    private let rightLabel = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rail.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        fill.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        for label in [leftLabel, rightLabel] {
            label.foregroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
            label.actions = ["contents": NSNull()]
        }
        leftLabel.alignmentMode = .left
        rightLabel.alignmentMode = .right
        [rail, fill, leftLabel, rightLabel].forEach { layer?.addSublayer($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(track: Track, scale: CGFloat, showRemaining: Bool) {
        self.track = track
        self.scale = scale
        self.showRemaining = showRemaining
        needsLayout = true
        updateTimer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        updateTimer()
    }

    private func updateTimer() {
        let wanted = window != nil && track?.isPlaying == true
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateLabels() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    private var labelWidth: CGFloat { 30 * scale }
    private var barRect: CGRect {
        let inset = labelWidth + 6 * scale
        return CGRect(x: inset, y: 0, width: max(10, bounds.width - inset * 2), height: bounds.height)
    }

    override func layout() {
        super.layout()
        guard let track else { return }
        let bar = barRect
        let thick = (hovering || dragFraction != nil ? 7 : 5) * scale
        let known = track.duration > 0
        let position = track.position()
        let fraction = dragFraction ?? (known ? CGFloat(position / track.duration) : 0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .medium)
        let lineHeight = ceil(font.ascender - font.descender) + 1

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        rail.frame = CGRect(x: bar.minX, y: (bar.height - thick) / 2, width: bar.width, height: thick)
        rail.cornerRadius = thick / 2
        fill.cornerRadius = thick / 2
        fill.position = CGPoint(x: bar.minX, y: bar.height / 2)
        CATransaction.setDisableActions(true)
        for label in [leftLabel, rightLabel] {
            label.font = font
            label.fontSize = font.pointSize
            label.contentsScale = window?.backingScaleFactor ?? 2
        }
        let labelY = (bar.height - lineHeight) / 2
        leftLabel.frame = CGRect(x: 0, y: labelY, width: labelWidth + 4 * scale, height: lineHeight)
        rightLabel.frame = CGRect(x: bounds.width - labelWidth - 4 * scale, y: labelY,
                                  width: labelWidth + 4 * scale, height: lineHeight)
        CATransaction.commit()

        // Bar: set the current width, then let the compositor run it to the end.
        fill.removeAnimation(forKey: "progress")
        let width = max(thick, bar.width * min(max(fraction, 0), 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = CGRect(x: 0, y: 0, width: width, height: thick)
        CATransaction.commit()
        if known, track.isPlaying, dragFraction == nil, window != nil, track.duration - position > 0.05 {
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = width
            animation.toValue = bar.width
            animation.duration = (track.duration - position) / (track.rate > 0 ? track.rate : 1)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            fill.add(animation, forKey: "progress")
        }
        updateLabels()
    }

    private func updateLabels() {
        guard let track else { return }
        guard track.duration > 0 else {
            leftLabel.string = "--:--"
            rightLabel.string = "--:--"
            return
        }
        let shown = dragFraction.map { Double($0) * track.duration } ?? track.position()
        leftLabel.string = TimeText.format(shown)
        rightLabel.string = showRemaining ? "-" + TimeText.format(track.duration - shown) : TimeText.format(track.duration)
    }

    // MARK: Mouse

    private func fraction(for event: NSEvent) -> CGFloat {
        let x = convert(event.locationInWindow, from: nil).x
        return min(max((x - barRect.minX) / barRect.width, 0), 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard let track, track.duration > 0 else { return }
        dragFraction = fraction(for: event)
        needsLayout = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragFraction != nil else { return }
        dragFraction = fraction(for: event)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let track, let dragFraction else { return }
        self.dragFraction = nil
        seek?(Double(dragFraction) * track.duration)
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsLayout = true }

    // MARK: VoiceOver: an adjustable slider that moves in 10-second steps

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { NSLocalizedString("Playback position", comment: "") }

    override func accessibilityValue() -> Any? {
        guard let track, track.duration > 0 else { return NSLocalizedString("Unknown", comment: "") }
        return String(format: NSLocalizedString("%@ of %@", comment: "position of duration"),
                      TimeText.format(track.position()), TimeText.format(track.duration))
    }

    override func accessibilityPerformIncrement() -> Bool { step(by: 10) }
    override func accessibilityPerformDecrement() -> Bool { step(by: -10) }

    private func step(by seconds: Double) -> Bool {
        guard let track, track.duration > 0 else { return false }
        seek?(min(max(track.position() + seconds, 0), track.duration))
        return true
    }
}

/// A control-row button with a soft rounded highlight on hover.
private struct ControlButton<Icon: View>: View {
    let width: CGFloat
    let height: CGFloat
    let label: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(Text(label))
    }

    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}
