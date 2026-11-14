import AppKit
import os
import PerchCore
import SwiftUI

/// Reads the system-wide "Now Playing" state through a tiny helper that runs
/// inside /usr/bin/perl (see Helper/PerchMediaHelper.m for why) and sends
/// playback commands back to it. When that service cannot be read, Spotify and
/// Music are still followed through the notifications they broadcast
/// (see FallbackPlayers). Nothing here touches the network.
final class MediaService: ObservableObject {
    static let shared = MediaService()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "media")

    @Published private(set) var track: Track?
    @Published private(set) var source: TrackSource = .none
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = .white
    @Published private(set) var sourceIcon: NSImage?
    @Published private(set) var sourceName: String?
    /// The system "Now Playing" service cannot be read; only the backup source works.
    @Published private(set) var helperFailed = false
    @Published private(set) var knownSources: [String] = Pref.strings(Pref.knownSources)
    @Published private(set) var ignoredSources: Set<String> = Set(Pref.strings(Pref.ignoredSources))

    let fallback = FallbackPlayers()

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let readQueue = DispatchQueue(label: "perch.media.read", qos: .userInitiated)
    private var restarts = 0
    private var totalRestarts = 0
    private var lastExitStatus: Int32?
    private var stopping = false
    private var fallbackEnabled = true
    private var defaultsObserver: NSObjectProtocol?

    // Latest state from the system service (main thread).
    private var systemTrack: Track?
    private var systemArtwork: NSImage?
    private var systemTint: Color = .white

    // Parsing state (read queue only).
    private var tracker = PositionTracker()
    private var lastArtworkId: String?
    private var lastArtwork: NSImage?
    private var lastTint: Color = .white

    // MARK: Lifecycle

    func start() {
        fallbackEnabled = Pref.bool(Pref.fallbackSources)
        fallback.onChange = { [weak self] in self?.publish() }
        fallback.start()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let enabled = Pref.bool(Pref.fallbackSources)
            if enabled != self.fallbackEnabled {
                self.fallbackEnabled = enabled
                self.publish()
            }
        }
        startHelper()
    }

    private func startHelper() {
        guard process == nil else { return }
        guard let script = Bundle.main.url(forResource: "perch-media-helper", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("PerchMediaHelper.dylib"),
              FileManager.default.fileExists(atPath: library.path) else {
            Self.log.error("The media helper is missing from the app bundle")
            markHelperFailed()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        process.environment = [:] // no PERL5LIB / PERL5OPT or anything else leaks into the helper
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of file: the handler would otherwise fire in a tight loop.
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.readQueue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            stdout.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.helperExited(status: status) }
        }

        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            Self.log.notice("Media helper started (pid \(process.processIdentifier))")
        } catch {
            Self.log.error("Media helper could not start: \(error.localizedDescription, privacy: .public)")
            markHelperFailed()
        }
    }

    func stop() {
        stopping = true
        fallback.stop()
        try? input?.close()
        process?.terminate()
        process = nil
    }

    /// Tries the system service again after Perch gave up on it.
    func retryHelper() {
        guard helperFailed, process == nil else { return }
        helperFailed = false
        restarts = 0
        Self.log.notice("Retrying the media helper")
        startHelper()
        publish()
    }

    private func helperExited(status: Int32) {
        process = nil
        input = nil
        lastExitStatus = status
        guard !stopping else { return }
        Self.log.error("Media helper exited with status \(status)")
        readQueue.async {
            self.buffer.removeAll()
            self.tracker.reset()
            self.lastArtworkId = nil
            self.lastArtwork = nil
            self.lastTint = .white
        }
        applySystem(track: nil, artwork: nil, tint: .white)
        restarts += 1
        totalRestarts += 1
        // Status 2: MediaRemote itself is unavailable, so restarting will not help.
        if status == 2 || restarts > 5 {
            markHelperFailed()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHelper() }
        }
    }

    private func markHelperFailed() {
        guard !helperFailed else { return }
        helperFailed = true
        Self.log.error("System Now Playing is unavailable; only the backup source is used")
        publish()
    }

    // MARK: Commands

    func send(_ command: MediaCommand) {
        switch source {
        case .fallback(let player):
            fallback.send(command, to: player)
        case .none where helperFailed:
            if let player = fallback.mostRecentPlayer { fallback.send(command, to: player) }
        default:
            write("send \(command.rawValue)")
        }
    }

    func togglePlayPause() { send(.toggle) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    func seek(to seconds: Double) {
        if case .fallback(let player) = source {
            fallback.seek(to: seconds, player: player)
            return
        }
        guard var current = systemTrack else { return }
        write(String(format: "seek %.3f", seconds))
        let now = Date()
        current.elapsed = seconds
        current.timestamp = now
        readQueue.async { self.tracker.noteSeek(to: seconds, at: now) }
        applySystem(track: current, artwork: systemArtwork, tint: systemTint)
    }

    func openSourceApp() {
        guard let id = track?.bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            self.input = nil // the helper is gone; its termination handler restarts it
        }
    }

    // MARK: Sources

    func setSource(_ id: String, enabled: Bool) {
        if enabled { ignoredSources.remove(id) } else { ignoredSources.insert(id) }
        Pref.set(Array(ignoredSources).sorted(), Pref.ignoredSources)
        publish()
    }

    func clearSources() {
        knownSources = track?.bundleId.map { [$0] } ?? []
        ignoredSources = []
        Pref.set(knownSources, Pref.knownSources)
        Pref.set([String](), Pref.ignoredSources)
        publish()
    }

    func reloadPreferences() {
        knownSources = Pref.strings(Pref.knownSources)
        ignoredSources = Set(Pref.strings(Pref.ignoredSources))
        fallbackEnabled = Pref.bool(Pref.fallbackSources)
        publish()
    }

    // MARK: Parsing (read queue)

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let update = NowPlayingParser.parse(line) else { return }
        guard let report = update.track else {
            tracker.reset()
            lastArtworkId = nil
            lastArtwork = nil
            lastTint = .white
            DispatchQueue.main.async {
                self.restarts = 0
                self.applySystem(track: nil, artwork: nil, tint: .white)
            }
            return
        }

        let track = tracker.ingest(report)
        if update.artworkId == nil {
            lastArtwork = nil
            lastTint = .white
        } else if let data = update.artworkData, let (image, tint) = Self.decodeArtwork(data) {
            lastArtwork = image
            lastTint = tint
        } else if update.artworkId != lastArtworkId {
            lastArtwork = nil
            lastTint = .white
        }
        lastArtworkId = update.artworkId

        let artwork = lastArtwork, tint = lastTint
        DispatchQueue.main.async {
            self.restarts = 0
            self.applySystem(track: track, artwork: artwork, tint: tint)
        }
    }

    /// Downscales the artwork (players often send multi-megabyte images) and picks a tint colour.
    private static func decodeArtwork(_ data: Data) -> (NSImage, Color)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        var tint = NSColor.white
        if let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                                  blue: CGFloat(pixel[2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Keep the hue, but make it bright enough to read on black.
            tint = NSColor(hue: h, saturation: min(1, s * 1.35 + 0.05), brightness: max(b, 0.88), alpha: 1)
        }
        let size = NSSize(width: image.width, height: image.height)
        return (NSImage(cgImage: image, size: size), Color(nsColor: tint))
    }

    // MARK: Publishing (main thread)

    private func applySystem(track: Track?, artwork: NSImage?, tint: Color) {
        systemTrack = track
        systemArtwork = artwork
        systemTint = tint
        publish()
    }

    private func publish() {
        let backup = fallbackEnabled ? fallback.tracks : []
        let selection = SourceSelector.select(primary: systemTrack, primaryAvailable: !helperFailed,
                                              fallback: backup, ignored: ignoredSources)
        remember(systemTrack?.bundleId)
        remember(selection.track?.bundleId)

        let previousApp = track?.bundleId
        if track != selection.track { track = selection.track }
        if source != selection.source {
            source = selection.source
            Self.log.notice("Showing source: \(String(describing: selection.source), privacy: .public)")
        }
        // Only the system service provides artwork.
        let fromSystem = selection.source == .system
        let newArtwork = fromSystem ? systemArtwork : nil
        if artwork !== newArtwork { artwork = newArtwork }
        let newTint = fromSystem ? systemTint : Color.white
        if tint != newTint { tint = newTint }
        if previousApp != track?.bundleId || (sourceIcon == nil && track != nil) {
            sourceIcon = track?.bundleId.flatMap(Self.icon(for:))
            sourceName = track?.bundleId.map(Self.name(for:))
        }
    }

    private func remember(_ id: String?) {
        guard let id, !knownSources.contains(id) else { return }
        knownSources.append(id)
        Pref.set(knownSources, Pref.knownSources)
    }

    static func icon(for bundleId: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func name(for bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Diagnostics

    /// No track names: the report is meant to be pasted into bug reports.
    func diagnosticRows() -> [(String, String)] {
        let service = helperFailed ? "unavailable" : (process != nil ? "running" : "restarting")
        let playback = track.map { $0.isPlaying ? "playing" : "paused" } ?? "nothing"
        let heard = fallback.tracks.compactMap(\.bundleId).joined(separator: ", ")
        return [
            ("System Now Playing", service),
            ("Helper restarts", "\(totalRestarts)"),
            ("Last helper exit status", lastExitStatus.map { "\($0)" } ?? "—"),
            ("Source shown", "\(source)"),
            ("Playback", playback),
            ("App", track?.bundleId ?? "—"),
            ("Duration known", track.map { $0.duration > 0 ? "yes" : "no" } ?? "—"),
            ("Artwork", artwork == nil ? "no" : "yes"),
            ("Backup source", fallbackEnabled ? "on" : "off"),
            ("Backup players active", heard.isEmpty ? "—" : heard),
            ("Apps turned off", "\(ignoredSources.count)"),
        ]
    }
}
