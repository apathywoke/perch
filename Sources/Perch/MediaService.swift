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
    /// Identifies the artwork image; changes only when the picture really changes.
    @Published private(set) var artworkKey: String?
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
    private var systemArtworkKey: String?
    private var systemTint: Color = .white

    // Parsing state (read queue only).
    private var tracker = PositionTracker()
    private var artworkTracker = ArtworkTracker()
    private var artworkCache: [String: (image: NSImage, tint: Color)] = [:]
    private var artworkRequested: String?
    private let spotifyClock = SpotifyClock()

    /// The lyrics just came on screen: check Spotify's position right away.
    func lyricsShown() { spotifyClock.checkSoon() }

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
        spotifyClock.onPosition = { [weak self] seconds, at, title in
            self?.correctPosition(to: seconds, at: at, title: title)
        }
        spotifyClock.start()
    }

    /// Spotify's own, exact position (see SpotifyClock) replaces the extrapolated one.
    private func correctPosition(to seconds: Double, at moment: Date, title: String) {
        guard var current = systemTrack, current.title == title, current.isPlaying,
              current.bundleId == FallbackPlayer.spotify.rawValue else { return }
        let error = current.position(at: moment) - seconds
        guard abs(error) > 0.04 else { return }
        if abs(error) > 0.4 {
            Self.log.notice("Spotify position corrected by \(String(format: "%+.2f", -error), privacy: .public) s")
        }
        spotifyClock.noteCorrection(-error)
        current.elapsed = seconds
        current.timestamp = moment
        readQueue.async { self.tracker.noteSeek(to: seconds, at: moment) }
        applySystem(track: current, artwork: systemArtwork, tint: systemTint, key: systemArtworkKey)
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
            self.artworkTracker.reset()
            self.artworkRequested = nil
        }
        applySystem(track: nil, artwork: nil, tint: .white, key: nil)
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
        applySystem(track: current, artwork: systemArtwork, tint: systemTint, key: systemArtworkKey)
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
            _ = artworkTracker.update(songId: nil, artworkId: nil, hasData: false)
            DispatchQueue.main.async {
                self.restarts = 0
                self.applySystem(track: nil, artwork: nil, tint: .white, key: nil)
            }
            return
        }

        let track = tracker.ingest(report)
        switch artworkTracker.update(songId: track.id, artworkId: update.artworkId, hasData: update.artworkData != nil) {
        case .decodeAndShow(let id):
            if let data = update.artworkData, let (image, tint) = Self.decodeArtwork(data) {
                artworkCache[id] = (image, tint)
            } else {
                artworkTracker.forget(id)
            }
        case .requestAndKeep(let id), .requestAndClear(let id):
            // The helper sends an image only once; ask again for one we do not hold.
            if artworkRequested != id {
                artworkRequested = id
                DispatchQueue.main.async { self.write("refresh") }
            }
        case .show, .keep, .clear:
            break
        }
        if artworkCache.count > artworkTracker.cachedIds.count {
            let kept = Set(artworkTracker.cachedIds)
            artworkCache = artworkCache.filter { kept.contains($0.key) }
        }

        let key = artworkTracker.shownId
        let entry = key.flatMap { artworkCache[$0] }
        if entry != nil, artworkRequested == key { artworkRequested = nil }
        DispatchQueue.main.async {
            self.restarts = 0
            self.applySystem(track: track, artwork: entry?.image, tint: entry?.tint ?? .white,
                             key: entry == nil ? nil : key)
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

    private func applySystem(track: Track?, artwork: NSImage?, tint: Color, key: String?) {
        systemTrack = track
        systemArtwork = artwork
        systemArtworkKey = key
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
        if track?.id != selection.track?.id || track?.isPlaying != selection.track?.isPlaying {
            spotifyClock.checkSoon()
        }
        if track != selection.track { track = selection.track }
        if source != selection.source {
            source = selection.source
            Self.log.notice("Showing source: \(String(describing: selection.source), privacy: .public)")
        }
        // Only the system service provides artwork.
        let fromSystem = selection.source == .system
        let newArtwork = fromSystem ? systemArtwork : nil
        if artwork !== newArtwork { artwork = newArtwork }
        let newKey = fromSystem ? systemArtworkKey : nil
        if artworkKey != newKey { artworkKey = newKey }
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

    // MARK: Preview

    /// A service that never starts the helper and shows a sample song, for the
    /// island preview in Settings when nothing is playing.
    /// Marks the sample song, so nothing is ever looked up for it.
    static let previewBundleId = "dev.perch.Perch.preview"

    /// Lyrics for the sample song, timed around its position.
    static let previewLyrics = Lyrics.synced(LRCParser.parse("""
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
        """))

    static func preview() -> MediaService {
        let service = MediaService()
        service.track = Track(title: NSLocalizedString("Song title", comment: "preview"),
                              artist: NSLocalizedString("Artist", comment: "preview"),
                              bundleId: previewBundleId,
                              duration: 214, elapsed: 71, timestamp: Date(), isPlaying: true)
        service.artwork = previewArtwork()
        service.artworkKey = "preview"
        service.tint = Color(nsColor: NSColor(srgbRed: 0.66, green: 0.52, blue: 1, alpha: 1))
        service.source = .system
        service.sourceIcon = icon(for: FallbackPlayer.music.rawValue)
        service.sourceName = service.sourceIcon == nil ? nil : name(for: FallbackPlayer.music.rawValue)
        return service
    }

    private static func previewArtwork() -> NSImage {
        NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.62, alpha: 1),
                                NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)])?
                .draw(in: rect, angle: -45)
            let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tinted = NSImage(size: note.size, flipped: false) { noteRect in
                    note.draw(in: noteRect)
                    NSColor.white.withAlphaComponent(0.92).set()
                    noteRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: (rect.width - note.size.width) / 2, y: (rect.height - note.size.height) / 2,
                                       width: note.size.width, height: note.size.height))
            }
            return true
        }
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
            ("Spotify position check", spotifyClock.denied ? "not allowed"
                : spotifyClock.lastCorrection.map { String(format: "last correction %+.2f s", $0) } ?? "no corrections yet"),
            ("Backup source", fallbackEnabled ? "on" : "off"),
            ("Backup players active", heard.isEmpty ? "—" : heard),
            ("Apps turned off", "\(ignoredSources.count)"),
        ]
    }
}
