import AppKit
import PerchCore
import SwiftUI

/// Developer tool: `Perch --snapshot-settings <folder>` draws every Settings pane
/// off screen, in light and dark mode, saves them as PNG files and quits.
/// Used to check the layout without a screen recording and for README images.
enum Snapshots {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot-events"), index + 1 < arguments.count {
            MainActor.assumeIsolated { snapshotEvents(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
        }
        if let index = arguments.firstIndex(of: "--snapshot-demo"), index + 1 < arguments.count {
            MainActor.assumeIsolated { snapshotDemo(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
        }
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
        if let track = media.track {
            LyricsService.shared.showWithoutFetching(MediaService.previewLyrics, for: track)
        }
        let model = NotchModel()
        model.notchSize = CGSize(width: 209, height: 38)
        model.hasNotch = true
        model.active = true
        model.visible = true
        model.phase = .expanded
        model.showLyrics = true
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 560),
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

    /// A short scripted run of the island over a mock menu bar, saved frame by
    /// frame for the README: `Scripts/make-demo.sh` turns the frames into a GIF.
    /// The song and its lyrics are made up. Default settings are used whatever
    /// this Mac has saved, and nothing is written to the saved settings.
    @MainActor
    private static func snapshotDemo(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        var settings = Pref.defaults
        settings[Pref.lyricsEnabled] = true
        settings[Pref.lyricsOpen] = true
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)

        // Recording starts once the window has settled. The lyrics reach the
        // middle of a line as the player opens.
        let start = Date().addingTimeInterval(1.2)
        let opens = 1.5, closes = 9.0
        let track = Track(title: "Hold the Note", artist: "Paper Boats", bundleId: MediaService.previewBundleId,
                          duration: 214, elapsed: 62.5 - opens, timestamp: start, isPlaying: true)
        let media = MediaService.preview(track: track)
        LyricsService.shared.showWithoutFetching(MediaService.previewLyrics, for: track)
        let russian = Bundle.main.preferredLocalizations.first == "ru"
        let model = NotchModel()
        model.notchSize = CGSize(width: 209, height: 38)
        model.hasNotch = true
        model.active = true
        model.visible = true
        model.showLyrics = true

        let canvas = CGSize(width: 760, height: 400)
        let scene = ZStack(alignment: .top) {
            DemoDesktop(russian: russian)
            IslandView(model: model, media: media)
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: canvas.width, height: canvas.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: scene)
        window.orderFrontRegardless()
        RunLoop.main.run(until: start)

        let airPods = IslandEvent.Kind.headphones(name: "AirPods Pro", symbol: "airpodspro", connected: true)
        let focus = IslandEvent.Kind.focus(name: russian ? "Не беспокоить" : "Do Not Disturb", on: true)
        var script: [(time: Double, action: () -> Void)] = [
            (1.0, { model.prepared = true; withAnimation(Motion.swell) { model.hovering = true } }),
            (opens, { withAnimation(Motion.grow) { model.phase = .expanded; model.hovering = false } }),
            (closes, { withAnimation(Motion.shrink) { model.phase = .collapsed } }),
            (closes + 0.6, { model.prepared = false }),
            (10.2, { withAnimation(Motion.grow) { model.event = IslandEvent(kind: airPods) } }),
            (13.0, { withAnimation(Motion.shrink) { model.event = nil } }),
            (13.8, { withAnimation(Motion.grow) { model.event = IslandEvent(kind: focus) } }),
            (16.6, { withAnimation(Motion.shrink) { model.event = nil } }),
        ]
        let length = 17.6, frameTime = 1.0 / 20

        // Frames are encoded off the main thread so capturing keeps its pace.
        let encoding = DispatchGroup()
        let queue = DispatchQueue(label: "demo.encode", qos: .userInitiated, attributes: .concurrent)
        var times: [String] = []
        var frame = 0
        while true {
            let target = Double(frame) * frameTime
            guard target <= length else { break }
            RunLoop.main.run(until: start.addingTimeInterval(target))
            let now = Date().timeIntervalSince(start)
            while let next = script.first, next.time <= now {
                script.removeFirst()
                next.action()
            }
            guard let image = capture(window) else { break }
            times.append(String(format: "%.3f", Date().timeIntervalSince(start)))
            let url = folder.appendingPathComponent(String(format: "frame-%04d.png", frame))
            queue.async(group: encoding) {
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else { return }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            frame += 1
        }
        encoding.wait()
        try? times.joined(separator: "\n").write(to: folder.appendingPathComponent("times.txt"),
                                                 atomically: true, encoding: .utf8)
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

    /// Every island event, frame by frame as it animates: one strip per event,
    /// beside the notch and below it.
    @MainActor
    private static func snapshotEvents(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Pref.register()
        let notch = CGSize(width: 209, height: 38)
        let samples: [(String, IslandEvent.Kind)] = [
            ("focus-on", .focus(name: "Do Not Disturb", on: true)),
            ("focus-work", .focus(name: "Work", on: true)),
            ("focus-off", .focus(name: "Do Not Disturb", on: false)),
            ("charging", .power(.pluggedIn(level: 0.62))),
            ("unplugged", .power(.unplugged(level: 0.62))),
            ("low", .power(.low(level: 0.1))),
            ("airpods-on", .headphones(name: "AirPods Pro", symbol: "airpodspro", connected: true)),
            ("airpods-off", .headphones(name: "AirPods Pro", symbol: "airpodspro", connected: false)),
            ("caps-on", .capsLock(on: true)),
            ("caps-off", .capsLock(on: false)),
            ("microphone", .microphone(app: "Zoom")),
            ("camera", .camera),
        ]
        let times = [0.02, 0.12, 0.25, 0.4, 0.7, 1.4]
        for (name, kind) in samples {
            for variant in ["beside", "below", "card"] {
                let size: CGSize, layout: EventLayout, radius: CGFloat
                switch variant {
                case "beside":
                    size = NotchLayout.eventSize(style: .beside, notch: notch, hasNotch: true)
                    layout = .compact(.beside(wing: NotchLayout.eventWing, height: notch.height))
                    radius = 10
                case "below":
                    size = NotchLayout.eventSize(style: .below, notch: notch, hasNotch: true)
                    layout = .compact(.below(notchHeight: notch.height))
                    radius = 24
                default:
                    size = NotchLayout.eventCardSize(notch: notch, hasNotch: true, scale: 1)
                    layout = .card(top: notch.height, scale: 1)
                    radius = 28
                }
                let view = ZStack(alignment: .top) {
                    Color(white: 0.3)
                    NotchShape(topRadius: 18, bottomRadius: radius).fill(.black)
                        .frame(width: size.width + 36, height: size.height)
                    // The camera housing, as on the real screen.
                    UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                        .fill(Color(white: 0.08))
                        .frame(width: notch.width, height: notch.height)
                    EventView(event: IslandEvent(kind: kind), layout: layout)
                        .frame(width: size.width, height: size.height, alignment: .top)
                }
                .frame(width: size.width + 40, height: size.height + 12)
                .environment(\.colorScheme, .dark)
                let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width + 40, height: size.height + 12),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: view)
                window.orderFrontRegardless()
                let start = Date()
                for (index, t) in times.enumerated() {
                    RunLoop.main.run(until: start.addingTimeInterval(t))
                    if let image = capture(window) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: folder.appendingPathComponent("\(name)-\(variant)-\(index).png"))
                    }
                }
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}

/// The top of a Mac screen behind the island in the README demo: a plain
/// wallpaper (a flat colour keeps the GIF small and free of banding) and a menu bar.
private struct DemoDesktop: View {
    let russian: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.13, green: 0.12, blue: 0.21)
            HStack(spacing: 20) {
                Text("Finder").fontWeight(.bold)
                ForEach(russian ? ["Файл", "Правка"] : ["File", "Edit"], id: \.self) { Text($0) }
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(russian ? "Сб 21:40" : "Sat 9:40 PM")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(Color.white.opacity(0.07))
        }
    }
}
