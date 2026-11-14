import AppKit
import os
import PerchCore

/// Backup source for when the system "Now Playing" service cannot be read,
/// for example after a macOS update closes it again.
///
/// Spotify and Music broadcast every playback change as a distributed
/// notification, which any app may receive without a permission. Controlling
/// them goes through AppleScript: macOS asks the user once per app the first
/// time that happens. The scripts run in osascript, so a permission prompt
/// never blocks Perch itself.
final class FallbackPlayers {
    static let log = Logger(subsystem: "dev.perch.Perch", category: "fallback")

    /// Current state per player, most recently updated first. Stopped players are dropped.
    private(set) var tracks: [Track] = []
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    var mostRecentPlayer: FallbackPlayer? { tracks.first?.bundleId.flatMap(FallbackPlayer.init(rawValue:)) }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for player in FallbackPlayer.allCases {
            let observer = center.addObserver(forName: Notification.Name(player.notificationName), object: nil,
                                              queue: .main) { [weak self] note in
                self?.update(player, with: note.userInfo ?? [:])
            }
            observers.append(observer)
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func update(_ player: FallbackPlayer, with info: [AnyHashable: Any]) {
        let report = FallbackParser.parse(info, player: player)
        let previous = tracks.first { $0.bundleId == player.rawValue }
        tracks.removeAll { $0.bundleId == player.rawValue }
        if let track = FallbackParser.merge(report, previous: previous) {
            tracks.insert(track, at: 0)
        }
        onChange?()
    }

    // MARK: Commands

    func send(_ command: MediaCommand, to player: FallbackPlayer) {
        let verb = switch command {
        case .play: "play"
        case .pause: "pause"
        case .toggle: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        run("tell application id \"\(player.rawValue)\" to \(verb)")
    }

    func seek(to seconds: Double, player: FallbackPlayer) {
        run("tell application id \"\(player.rawValue)\" to set player position to \(String(format: "%.2f", seconds))")
        if let index = tracks.firstIndex(where: { $0.bundleId == player.rawValue }) {
            tracks[index].elapsed = seconds
            tracks[index].timestamp = Date()
            onChange?()
        }
    }

    /// The scripts are fixed strings built from the enums above; nothing typed
    /// by the user or received from a player ends up in them.
    private func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = [:]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Self.log.error("AppleScript failed (\(finished.terminationStatus)): \(message, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            Self.log.error("osascript could not start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
