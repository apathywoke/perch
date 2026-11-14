import AppKit
import PerchCore
import SwiftUI

/// Developer tool: `Perch --snapshot-settings <folder>` draws every Settings pane
/// off screen, in light and dark mode, saves them as PNG files and quits.
/// Used to check the layout without a screen recording and for README images.
enum Snapshots {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot-lyrics"), index + 1 < arguments.count {
            snapshotLyrics(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        guard let index = arguments.firstIndex(of: "--snapshot-settings"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Pref.register()
        let previousPane = UserDefaults.standard.string(forKey: Pref.settingsPane)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            for pane in SettingsPane.allCases {
                UserDefaults.standard.set(pane.rawValue, forKey: Pref.settingsPane)
                let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 820, height: 610),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                let host = NSHostingView(rootView: SettingsView())
                window.contentView = host
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                if let image = capture(window) {
                    let name = "\(pane.rawValue)-\(appearance == .darkAqua ? "dark" : "light").png"
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent(name))
                }
                window.orderOut(nil)
            }
        }
        UserDefaults.standard.set(previousPane, forKey: Pref.settingsPane)
        exit(0)
    }

    /// The open island with lyrics of a made-up song, in the middle of a verse.
    /// Run with `-lyricsEnabled YES` so the setting is on for this process only.
    private static func snapshotLyrics(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        Pref.register()
        let media = MediaService.preview()
        let lrc = """
        [00:52.00]Streetlights hum a quiet tune
        [00:56.00]Paper boats on a silver lake
        [01:00.00]We kept the window open wide
        [01:04.50]And let the evening in
        [01:09.00]Every song we never wrote
        [01:11.50]Is waiting in the rain
        [01:17.50]
        [01:21.00]So hold the note a little longer
        [01:25.00]Before the morning comes
        [01:29.00]Hold the note
        """
        if let track = media.track {
            LyricsService.shared.showWithoutFetching(.synced(LRCParser.parse(lrc)), for: track)
        }
        let model = NotchModel()
        model.notchSize = CGSize(width: 209, height: 38)
        model.hasNotch = true
        model.active = true
        model.visible = true
        model.phase = .expanded
        model.showLyrics = true
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.3, alpha: 1)
        window.contentView = NSHostingView(rootView: IslandView(model: model, media: media))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if let image = capture(window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("lyrics.png"))
        }
        exit(0)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// An app may capture its own windows without the Screen Recording permission.
    /// CGWindowListCreateImage is deprecated in favour of ScreenCaptureKit, which
    /// would ask for that permission, so it is looked up at run time.
    private static func capture(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?
            .takeRetainedValue()
    }
}
