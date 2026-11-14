import CoreGraphics

public enum IslandPhase: String, CaseIterable {
    case collapsed, peek, expanded
}

/// Where the volume and brightness indicator appears.
public enum HUDStyle: String, CaseIterable, Identifiable {
    case beside, below
    public var id: String { rawValue }
}

/// All island measurements, in points.
public enum NotchLayout {
    /// Radius of the concave corners that blend the island into the screen edge.
    public static let earRadius: CGFloat = 6

    // Track-change card.
    public static let peekRow: CGFloat = 44
    public static let peekArtwork: CGFloat = 52
    public static let peekSide: CGFloat = 70

    /// How much the collapsed island grows while the pointer rests on it.
    public static let hoverGrowth = CGSize(width: 26, height: 7)

    // Volume and brightness indicator.
    public static let hudWing: CGFloat = 96
    public static let hudRow: CGFloat = 36

    /// The island's resting size on displays without a notch.
    public static let virtualNotch = CGSize(width: 184, height: 32)

    public struct Geometry: Equatable {
        public var hasNotch: Bool
        public var notch: CGSize
    }

    /// The notch is the gap between the two menu bar areas beside the camera.
    public static func geometry(screenWidth: CGFloat, safeAreaTop: CGFloat,
                                leftAuxWidth: CGFloat?, rightAuxWidth: CGFloat?) -> Geometry {
        guard safeAreaTop > 0 else { return Geometry(hasNotch: false, notch: virtualNotch) }
        var width: CGFloat = 200
        if let left = leftAuxWidth, let right = rightAuxWidth {
            let gap = screenWidth - left - right
            if gap > 60, gap < screenWidth / 2 { width = gap }
        }
        return Geometry(hasNotch: true, notch: CGSize(width: width, height: safeAreaTop))
    }

    /// Width added on each side of the notch for the artwork and the visualizer.
    public static func wing(_ notch: CGSize) -> CGFloat { notch.height + 4 }

    /// Positions inside the expanded player, in points from its top-left corner.
    /// The artwork sits beside the notch and the text below it, so no band of
    /// empty black is left under the camera.
    public struct PlayerMetrics: Equatable {
        public var width: CGFloat
        public var height: CGFloat
        public var inset: CGFloat
        public var artTop: CGFloat
        public var art: CGFloat
        public var textLeading: CGFloat
        public var textTop: CGFloat
        public var scrubberCenter: CGFloat
        public var controlsCenter: CGFloat
        /// Extra row for the volume or brightness indicator while the player is open.
        public var hudRow: CGFloat
        /// Distance between the centres of the buttons in the control row.
        public var controlSpacing: CGFloat
    }

    public static func player(notch: CGSize, hasNotch: Bool, scale s: CGFloat) -> PlayerMetrics {
        let inset = 18 * s, art = 56 * s, artTop = 18 * s
        // Wide enough for the artwork to fit beside the notch.
        let width = max(368 * s, notch.width + 2 * (inset + art + 4 * s))
        // Text starts under the notch, which it would otherwise disappear behind.
        let textTop = hasNotch ? max(notch.height + 6, 28 * s) : 28 * s
        let scrubber = max(artTop + art + 20 * s, textTop + 50 * s)
        let controls = scrubber + 40 * s
        return PlayerMetrics(width: width, height: controls + 44 * s, inset: inset, artTop: artTop, art: art,
                             textLeading: inset + art + 16 * s, textTop: textTop, scrubberCenter: scrubber,
                             controlsCenter: controls, hudRow: 34 * s, controlSpacing: 72 * s)
    }

    /// Room for about `lines` single-line lyrics in a `fontSize` font: each line
    /// with its spacing, plus a little for the fades at the top and bottom.
    public static func lyricsHeight(lines: Int, fontSize: CGFloat) -> CGFloat {
        (CGFloat(max(1, lines)) * fontSize * 1.8 + fontSize * 0.8).rounded()
    }

    public static func hudSize(style: HUDStyle, notch: CGSize, hasNotch: Bool) -> CGSize {
        if !hasNotch { return CGSize(width: 290, height: notch.height) }
        switch style {
        case .beside: return CGSize(width: notch.width + 2 * hudWing, height: notch.height)
        case .below: return CGSize(width: max(notch.width + 2 * wing(notch), 330), height: notch.height + hudRow)
        }
    }

    /// The island's size, without the ears.
    /// - Parameters:
    ///   - hud: style of the volume or brightness indicator on screen, if any.
    ///   - swell: the pointer rests on the collapsed island.
    ///   - lyricsHeight: room for lyrics under the controls of the open player; 0 for none.
    public static func size(phase: IslandPhase, notch: CGSize, hasNotch: Bool, active: Bool, scale: CGFloat,
                            hud: HUDStyle? = nil, swell: Bool = false, lyricsHeight: CGFloat = 0) -> CGSize {
        if phase == .expanded {
            let player = player(notch: notch, hasNotch: hasNotch, scale: scale)
            return CGSize(width: player.width,
                          height: player.height + max(0, lyricsHeight) + (hud == nil ? 0 : player.hudRow))
        }
        if let hud { return hudSize(style: hud, notch: notch, hasNotch: hasNotch) }
        if phase == .peek, active {
            return CGSize(width: max(notch.width + 2 * peekSide, 330), height: notch.height + peekRow)
        }
        var size = active ? CGSize(width: notch.width + 2 * wing(notch), height: notch.height) : notch
        if swell, phase == .collapsed {
            size.width += hoverGrowth.width
            size.height += hoverGrowth.height
        }
        return size
    }
}
