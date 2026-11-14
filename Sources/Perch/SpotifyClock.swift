import Foundation
import os
import PerchCore

/// Keeps the position of a Spotify song exact while lyrics are open.
///
/// What Spotify tells the system "Now Playing" service drifts: after a skip
/// it restarts its clock half a second late, sometimes reports the start of a
/// song seconds after the song began, and rarely corrects itself afterwards.
/// For lyrics that is far too much. Spotify's own `player position`, asked
/// through AppleScript, is exact, so while lyrics are open Perch asks for it
/// every couple of seconds and right after a song starts. macOS asks the user
/// once before Perch may talk to Spotify.
final class SpotifyClock {
    static let log = Logger(subsystem: "dev.perch.Perch", category: "spotify-clock")

    /// Spotify's position for the named song at the given moment.
    var onPosition: ((_ seconds: Double, _ at: Date, _ title: String) -> Void)?
    private(set) var denied = false
    private(set) var lastCorrection: Double?
    private var timer: Timer?
    private var asking = false

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Something changed (a new song, play, seek): check soon rather than on the next tick.
    func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.tick() }
    }

    func noteCorrection(_ seconds: Double) { lastCorrection = seconds }

    private var wanted: Bool {
        guard !denied, Pref.bool(Pref.lyricsEnabled), Pref.bool(Pref.lyricsOpen),
              let track = MediaService.shared.track, track.isPlaying,
              track.bundleId == FallbackPlayer.spotify.rawValue else { return false }
        return true
    }

    private func tick() {
        guard wanted, !asking else { return }
        asking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.ask()
            DispatchQueue.main.async {
                self.asking = false
                switch result {
                case .position(let seconds, let at, let title):
                    self.onPosition?(seconds, at, title)
                case .denied:
                    self.denied = true
                    Self.log.notice("Not allowed to ask Spotify for its position; using the system's")
                case .failed:
                    break
                }
            }
        }
    }

    enum Answer {
        case position(Double, Date, String)
        case denied
        case failed
    }

    /// A fixed script, nothing from outside goes into it. Spotify answers at the
    /// very end of the run, so the position belongs to the moment osascript exits
    /// (measured: within a millisecond).
    private static func ask() -> Answer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            tell application id "com.spotify.client"
                if player state is playing then return (player position as text) & linefeed & (name of current track)
            end tell
            """]
        process.environment = [:]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let at = Date()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // -1743: the user did not allow Perch to control Spotify.
            return message.contains("-1743") ? .denied : .failed
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = text.firstIndex(of: "\n"),
              let seconds = Double(text[..<newline].replacingOccurrences(of: ",", with: ".")) else { return .failed }
        return .position(seconds, at, String(text[text.index(after: newline)...]))
    }
}
