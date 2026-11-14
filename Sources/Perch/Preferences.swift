import PerchCore
import SwiftUI

/// All user settings live in UserDefaults. Views bind with @AppStorage,
/// everything else reads through the typed helpers below.
enum Pref {
    // General
    static let showMenuBarIcon = "showMenuBarIcon"
    static let display = "display"
    static let hideInFullscreen = "hideInFullscreen"
    static let showOnNonNotch = "showOnNonNotch"
    static let hideFromCapture = "hideFromCapture"
    // Behaviour
    static let openTrigger = "openTrigger"
    static let hoverDelay = "hoverDelay"
    static let closeDelay = "closeDelay"
    static let clickAction = "clickAction"
    static let haptics = "haptics"
    static let peekOnTrackChange = "peekOnTrackChange"
    static let peekDuration = "peekDuration"
    static let hidePausedAfter = "hidePausedAfter"
    static let swipeGestures = "swipeGestures"
    static let invertSwipe = "invertSwipe"
    // Appearance
    static let scale = "scale"
    static let animation = "animation"
    static let visualizer = "visualizer"
    static let visualizerColor = "visualizerColor"
    static let swapSides = "swapSides"
    static let artworkGlow = "artworkGlow"
    static let showAlbum = "showAlbum"
    static let timeStyle = "timeStyle"
    static let shadow = "shadow"
    // Volume & brightness indicators
    static let hudEnabled = "hudEnabled"
    static let hudVolume = "hudVolume"
    static let hudBrightness = "hudBrightness"
    static let hudStyle = "hudStyle"
    static let hudPercent = "hudPercent"
    static let hudColor = "hudColor"
    static let hudDuration = "hudDuration"
    static let hudAskedForAccess = "hudAskedForAccess"
    // Sources
    static let ignoredSources = "ignoredSources"
    static let knownSources = "knownSources"
    static let fallbackSources = "fallbackSources"
    // First launch
    static let onboardingDone = "onboardingDone"
    // Settings window
    static let settingsPane = "settingsPane"
    // Lyrics (off unless the user turns them on)
    static let lyricsEnabled = "lyricsEnabled"
    static let lyricsOpen = "lyricsOpen"
    static let lyricsSize = "lyricsSize"
    static let lyricsWordByWord = "lyricsWordByWord"
    static let lyricsSpace = "lyricsSpace"
    // Updates (off unless the user turns them on)
    static let updateChecks = "updateChecks"
    static let lastUpdateCheck = "lastUpdateCheck"
    // Shortcuts
    static let hotkeys = "hotkeys"

    static let defaults: [String: Any] = [
        showMenuBarIcon: true,
        display: DisplayChoice.auto.rawValue,
        hideInFullscreen: true,
        showOnNonNotch: true,
        hideFromCapture: false,
        openTrigger: OpenTrigger.hover.rawValue,
        hoverDelay: 0.35,
        closeDelay: 0.25,
        clickAction: ClickAction.expand.rawValue,
        haptics: true,
        peekOnTrackChange: true,
        peekDuration: 3.0,
        hidePausedAfter: 30.0,
        swipeGestures: true,
        invertSwipe: false,
        scale: 1.0,
        animation: AnimationStyle.smooth.rawValue,
        visualizer: true,
        visualizerColor: VisualizerColor.artwork.rawValue,
        swapSides: false,
        artworkGlow: true,
        showAlbum: false,
        timeStyle: TimeStyle.remaining.rawValue,
        shadow: true,
        hudEnabled: true,
        hudVolume: true,
        hudBrightness: true,
        hudStyle: HUDStyle.beside.rawValue,
        hudPercent: true,
        hudColor: VisualizerColor.white.rawValue,
        hudDuration: 1.6,
        fallbackSources: true,
        updateChecks: false,
        lyricsEnabled: false,
        lyricsOpen: false,
        lyricsSize: LyricsSize.medium.rawValue,
        lyricsWordByWord: true,
        lyricsSpace: LyricsSpace.medium.rawValue,
    ]

    private static var store: UserDefaults { .standard }

    static func register() { store.register(defaults: defaults) }

    static func resetAll() {
        for key in defaults.keys { store.removeObject(forKey: key) }
        for key in [ignoredSources, knownSources, hotkeys] { store.removeObject(forKey: key) }
    }

    static func bool(_ key: String) -> Bool { store.bool(forKey: key) }
    static func double(_ key: String) -> Double { store.double(forKey: key) }
    static func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        store.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
    static func strings(_ key: String) -> [String] { store.stringArray(forKey: key) ?? [] }
    static func set(_ value: Any?, _ key: String) { store.set(value, forKey: key) }
}

enum DisplayChoice: String, CaseIterable, Identifiable {
    case auto, main, active
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .auto: "Automatic (prefer the notch)"
        case .main: "Main display"
        case .active: "Display with the active window"
        }
    }
}

enum OpenTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .hover: "On hover"
        case .click: "On click"
        }
    }
}

enum ClickAction: String, CaseIterable, Identifiable {
    case expand, playPause, openApp, none
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .expand: "Expand the island"
        case .playPause: "Play / pause"
        case .openApp: "Open the music app"
        case .none: "Do nothing"
        }
    }
}

enum AnimationStyle: String, CaseIterable, Identifiable {
    case snappy, smooth, relaxed
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .snappy: "Snappy"
        case .smooth: "Smooth"
        case .relaxed: "Relaxed"
        }
    }
    /// Opening overshoots a touch; closing is critically damped, so it settles
    /// against the notch without a bounce. "Smooth" matches the timing measured
    /// frame by frame from a screen recording of a well-regarded notch app.
    var open: Animation {
        switch self {
        case .snappy: .spring(response: 0.3, dampingFraction: 0.8)
        case .smooth: .spring(response: 0.38, dampingFraction: 0.78)
        case .relaxed: .spring(response: 0.52, dampingFraction: 0.8)
        }
    }
    var close: Animation {
        switch self {
        case .snappy: .spring(response: 0.32, dampingFraction: 1)
        case .smooth: .spring(response: 0.41, dampingFraction: 1)
        case .relaxed: .spring(response: 0.56, dampingFraction: 1)
        }
    }
    /// Content appears a beat after the island starts to grow, so the shape leads.
    var contentIn: Animation {
        switch self {
        case .snappy: .spring(response: 0.3, dampingFraction: 0.9).delay(0.03)
        case .smooth: .spring(response: 0.42, dampingFraction: 0.9).delay(0.06)
        case .relaxed: .spring(response: 0.6, dampingFraction: 0.9).delay(0.1)
        }
    }
}

enum VisualizerColor: String, CaseIterable, Identifiable {
    case artwork, white, accent
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .artwork: "From the artwork"
        case .white: "White"
        case .accent: "System accent"
        }
    }
}

enum LyricsSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
    var points: CGFloat {
        switch self {
        case .small: 16
        case .medium: 19
        case .large: 23
        }
    }
}

/// How much of the lyrics the open player shows at once.
enum LyricsSpace: String, CaseIterable, Identifiable {
    case few, medium, many
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .few: "Few lines"
        case .medium: "Medium"
        case .many: "Many lines"
        }
    }
    var lines: Int {
        switch self {
        case .few: 3
        case .medium: 5
        case .many: 8
        }
    }

    /// Height under the controls for the current settings, 0 when lyrics are closed or off.
    static func currentHeight(scale: CGFloat) -> CGFloat {
        guard Pref.bool(Pref.lyricsEnabled), NotchController.shared.model.showLyrics else { return 0 }
        let space = Pref.value(Pref.lyricsSpace, LyricsSpace.medium)
        let size = Pref.value(Pref.lyricsSize, LyricsSize.medium)
        return NotchLayout.lyricsHeight(lines: space.lines, fontSize: size.points * scale)
    }
}

enum TimeStyle: String, CaseIterable, Identifiable {
    case remaining, total
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .remaining: "Time remaining"
        case .total: "Total duration"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .en: "English"
        case .ru: "Русский"
        }
    }

    static var current: AppLanguage {
        get {
            // Only an explicit per-app override counts; the global list is the system language.
            let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
            guard let code = own?.first else { return .system }
            return code.hasPrefix("ru") ? .ru : .en
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }
}
