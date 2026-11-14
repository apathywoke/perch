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

    // Expanded player, multiplied by the size setting.
    public static let artwork: CGFloat = 58
    public static let inset: CGFloat = 22
    public static let insetTop: CGFloat = 8

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

    /// Space above the expanded content: the notch itself, or a small margin without one.
    public static func topInset(hasNotch: Bool, notch: CGSize) -> CGFloat { hasNotch ? notch.height : 10 }

    public static func hudSize(style: HUDStyle, notch: CGSize, hasNotch: Bool) -> CGSize {
        if !hasNotch { return CGSize(width: 290, height: notch.height) }
        switch style {
        case .beside: return CGSize(width: notch.width + 2 * hudWing, height: notch.height)
        case .below: return CGSize(width: max(notch.width + 2 * wing(notch), 330), height: notch.height + hudRow)
        }
    }

    /// The island's size, without the ears.
    public static func size(phase: IslandPhase, notch: CGSize, hasNotch: Bool, active: Bool, scale: CGFloat,
                            hud: HUDStyle? = nil) -> CGSize {
        if let hud, phase != .expanded { return hudSize(style: hud, notch: notch, hasNotch: hasNotch) }
        switch phase {
        case .expanded:
            return CGSize(width: max(388 * scale, notch.width + 60),
                          height: topInset(hasNotch: hasNotch, notch: notch) + 168 * scale)
        case .peek where active:
            return CGSize(width: max(notch.width + 2 * peekSide, 330), height: notch.height + peekRow)
        default:
            return active ? CGSize(width: notch.width + 2 * wing(notch), height: notch.height) : notch
        }
    }
}
