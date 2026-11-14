import Foundation

// MARK: - System "Now Playing" (the media helper)

/// One message from the media helper (Helper/PerchMediaHelper.m).
public struct NowPlayingUpdate: Equatable {
    /// `nil` when nothing is playing.
    public var track: Track?
    public var artworkId: String?
    /// Sent only when the artwork changes.
    public var artworkData: Data?

    public init(track: Track?, artworkId: String? = nil, artworkData: Data? = nil) {
        self.track = track
        self.artworkId = artworkId
        self.artworkData = artworkData
    }
}

public enum NowPlayingParser {
    /// Parses one JSON line. Returns `nil` for anything that is not a JSON object.
    public static func parse(_ line: Data, now: Date = Date()) -> NowPlayingUpdate? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return parse(json, now: now)
    }

    public static func parse(_ json: [String: Any], now: Date = Date()) -> NowPlayingUpdate {
        guard let title = json["title"] as? String, !title.isEmpty else { return NowPlayingUpdate(track: nil) }
        let track = Track(
            title: title,
            artist: json["artist"] as? String ?? "",
            album: json["album"] as? String ?? "",
            bundleId: json["bundleId"] as? String,
            duration: number(json["duration"]) ?? 0,
            elapsed: number(json["elapsed"]) ?? 0,
            timestamp: number(json["timestamp"]).map(Date.init(timeIntervalSince1970:)) ?? now,
            rate: number(json["rate"]) ?? 1,
            isPlaying: json["playing"] as? Bool ?? false
        )
        return NowPlayingUpdate(track: track,
                                artworkId: json["artworkId"] as? String,
                                artworkData: (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) })
    }
}

// MARK: - Backup source (Spotify and Music notifications)

/// Players that announce playback changes with distributed notifications.
/// Used when the system "Now Playing" service cannot be read.
public enum FallbackPlayer: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    public var notificationName: String {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }
}

public struct FallbackReport: Equatable {
    /// `nil` when the player stopped.
    public var track: Track?
    /// Spotify sends the position; Music does not.
    public var positionKnown: Bool
}

public enum FallbackParser {
    public static func parse(_ info: [AnyHashable: Any], player: FallbackPlayer, now: Date = Date()) -> FallbackReport {
        let state = (info["Player State"] as? String)?.lowercased()
        guard state == "playing" || state == "paused",
              let title = info["Name"] as? String, !title.isEmpty else {
            return FallbackReport(track: nil, positionKnown: false)
        }
        // Both players give the length in milliseconds.
        let milliseconds = number(info["Duration"]) ?? number(info["Total Time"]) ?? 0
        let position = number(info["Playback Position"])
        let track = Track(
            title: title,
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            bundleId: player.rawValue,
            duration: max(0, milliseconds / 1000),
            elapsed: position ?? 0,
            timestamp: now,
            rate: 1,
            isPlaying: state == "playing"
        )
        return FallbackReport(track: track, positionKnown: position != nil)
    }

    /// Without a reported position, continue the estimate for the same song;
    /// a different song has just started.
    public static func merge(_ report: FallbackReport, previous: Track?, now: Date = Date()) -> Track? {
        guard var track = report.track else { return nil }
        if !report.positionKnown {
            track.elapsed = (previous?.id == track.id ? previous?.position(at: now) : nil) ?? 0
            track.timestamp = now
        }
        return track
    }
}

// MARK: - Choosing what the island shows

public enum TrackSource: Equatable {
    case none
    /// The system "Now Playing" service.
    case system
    /// The backup source, for the given player.
    case fallback(FallbackPlayer)
}

public enum SourceSelector {
    /// - Parameters:
    ///   - primary: what the system "Now Playing" service reports.
    ///   - primaryAvailable: whether that service can be read at all.
    ///   - fallback: tracks from the backup source, most recent first.
    ///   - ignored: bundle identifiers the user turned off.
    public static func select(primary: Track?, primaryAvailable: Bool, fallback: [Track],
                              ignored: Set<String>) -> (track: Track?, source: TrackSource) {
        func allowed(_ track: Track) -> Bool { track.bundleId.map { !ignored.contains($0) } ?? true }

        if primaryAvailable, let primary, allowed(primary) { return (primary, .system) }

        let candidates = fallback.filter(allowed)
        // While the system service works, the backup only steps in for music that is
        // actually playing (the service missed it). Without the service, a paused
        // player is shown too, as the system would.
        let pick = candidates.first(where: \.isPlaying) ?? (primaryAvailable ? nil : candidates.first)
        if let pick, let player = pick.bundleId.flatMap(FallbackPlayer.init(rawValue:)) {
            return (pick, .fallback(player))
        }
        return (nil, .none)
    }
}

// MARK: -

/// JSON and notification payloads carry numbers as NSNumber, sometimes as integers.
func number(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: number.doubleValue
    case let double as Double: double
    case let int as Int: Double(int)
    default: nil
    }
}
