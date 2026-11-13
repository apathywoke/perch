import AppKit
import SwiftUI

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var bundleId: String?
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool

    /// Identity of the song itself, ignoring playback position.
    var id: String { "\(title)\u{1}\(artist)\u{1}\(album)" }

    func position(at date: Date = Date()) -> Double {
        var value = elapsed
        if isPlaying { value += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        value = max(0, value)
        return duration > 0 ? min(value, duration) : value
    }
}

enum MediaCommand: Int {
    case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
}

/// Reads the system-wide "Now Playing" state through a tiny helper that runs
/// inside /usr/bin/perl (see Helper/PerchMediaHelper.m for why), and sends
/// playback commands back to it. Nothing here touches the network or the disk.
final class MediaService: ObservableObject {
    static let shared = MediaService()

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = .white
    @Published private(set) var sourceIcon: NSImage?
    @Published private(set) var helperFailed = false
    @Published private(set) var knownSources: [String] = Pref.strings(Pref.knownSources)
    @Published private(set) var ignoredSources: Set<String> = Set(Pref.strings(Pref.ignoredSources))

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let readQueue = DispatchQueue(label: "perch.media.read", qos: .userInitiated)
    private var restarts = 0
    private var stopping = false

    private var rawTrack: Track?
    private var rawArtwork: NSImage?
    private var rawTint: Color = .white

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        guard let script = Bundle.main.url(forResource: "perch-media-helper", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("PerchMediaHelper.dylib"),
              FileManager.default.fileExists(atPath: library.path) else {
            helperFailed = true
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
        process.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.helperExited() }
        }

        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
        } catch {
            helperFailed = true
        }
    }

    func stop() {
        stopping = true
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func helperExited() {
        process = nil
        input = nil
        guard !stopping else { return }
        readQueue.async { self.buffer.removeAll() }
        apply(track: nil, artwork: nil, tint: .white)
        restarts += 1
        if restarts > 5 {
            helperFailed = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        }
    }

    // MARK: Commands

    func send(_ command: MediaCommand) { write("send \(command.rawValue)") }
    func togglePlayPause() { send(.toggle) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    func seek(to seconds: Double) {
        guard var current = rawTrack else { return }
        write(String(format: "seek %.3f", seconds))
        current.elapsed = seconds
        current.timestamp = Date()
        apply(track: current, artwork: rawArtwork, tint: rawTint)
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
            self.input = nil // the helper is gone; it is restarted by its termination handler
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

    private var lastArtworkId: String?
    private var lastArtwork: NSImage?
    private var lastTint: Color = .white

    private var lastParsed: Track?
    private var lastReported: (elapsed: Double, timestamp: Date)?

    /// Many players report the position only when a track starts or is seeked.
    /// While playing we extrapolate from that; when playback pauses or resumes
    /// without a fresh report, the report is stale and has to be re-based on
    /// the position we had already reached.
    private static func correctedPosition(_ track: Track, previous: Track?,
                                          reported: inout (elapsed: Double, timestamp: Date)?) -> Track {
        var track = track
        let stale = reported.map { $0.elapsed == track.elapsed && $0.timestamp == track.timestamp } ?? false
        reported = (track.elapsed, track.timestamp)
        guard stale, let previous, previous.id == track.id else { return track }

        if !track.isPlaying {
            // Paused (or still paused): freeze where playback actually stopped.
            track.elapsed = previous.position()
            track.timestamp = Date()
        } else if !previous.isPlaying {
            // Resumed: continue from the frozen position, not from the old report.
            track.elapsed = previous.elapsed
            track.timestamp = Date()
        } else {
            track.elapsed = previous.elapsed
            track.timestamp = previous.timestamp
        }
        return track
    }

    private func handle(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let title = json["title"] as? String else {
            lastArtworkId = nil; lastArtwork = nil; lastTint = .white
            lastParsed = nil; lastReported = nil
            DispatchQueue.main.async { self.restarts = 0; self.apply(track: nil, artwork: nil, tint: .white) }
            return
        }
        var track = Track(
            title: title,
            artist: json["artist"] as? String ?? "",
            album: json["album"] as? String ?? "",
            bundleId: json["bundleId"] as? String,
            duration: json["duration"] as? Double ?? 0,
            elapsed: json["elapsed"] as? Double ?? 0,
            timestamp: (json["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date(),
            rate: json["rate"] as? Double ?? 1,
            isPlaying: json["playing"] as? Bool ?? false
        )

        track = Self.correctedPosition(track, previous: lastParsed, reported: &lastReported)
        lastParsed = track

        let artworkId = json["artworkId"] as? String
        if artworkId == nil {
            lastArtwork = nil; lastTint = .white
        } else if let encoded = json["artwork"] as? String, let data = Data(base64Encoded: encoded),
                  let (image, tint) = Self.decodeArtwork(data) {
            lastArtwork = image; lastTint = tint
        } else if artworkId != lastArtworkId {
            lastArtwork = nil; lastTint = .white
        }
        lastArtworkId = artworkId

        let artwork = lastArtwork, tint = lastTint
        DispatchQueue.main.async {
            self.restarts = 0
            self.apply(track: track, artwork: artwork, tint: tint)
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

    private func apply(track: Track?, artwork: NSImage?, tint: Color) {
        rawTrack = track
        rawArtwork = artwork
        rawTint = tint
        if let id = track?.bundleId, !knownSources.contains(id) {
            knownSources.append(id)
            Pref.set(knownSources, Pref.knownSources)
        }
        publish()
    }

    private func publish() {
        var visible = rawTrack
        if let id = visible?.bundleId, ignoredSources.contains(id) { visible = nil }
        let previousSource = track?.bundleId
        if track != visible { track = visible }
        let newArtwork = visible == nil ? nil : rawArtwork
        if artwork !== newArtwork { artwork = newArtwork }
        let newTint = visible == nil ? Color.white : rawTint
        if tint != newTint { tint = newTint }
        if previousSource != visible?.bundleId || (sourceIcon == nil && visible != nil) {
            sourceIcon = visible?.bundleId.flatMap(Self.icon(for:))
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
}
