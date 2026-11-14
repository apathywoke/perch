import Foundation

/// One song as reported by a player, with enough timing data to work out the
/// playback position at any moment without asking the player again.
public struct Track: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// The app that plays it.
    public var bundleId: String?
    /// Length in seconds; 0 when unknown (live streams, some browsers).
    public var duration: Double
    /// Position in seconds at `timestamp`.
    public var elapsed: Double
    public var timestamp: Date
    public var rate: Double
    public var isPlaying: Bool

    public init(title: String, artist: String = "", album: String = "", bundleId: String? = nil,
                duration: Double = 0, elapsed: Double = 0, timestamp: Date = Date(), rate: Double = 1,
                isPlaying: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.bundleId = bundleId
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.isPlaying = isPlaying
    }

    /// Identity of the song itself, ignoring playback position.
    public var id: String { "\(title)\u{1}\(artist)\u{1}\(album)" }

    /// Playback position at `date`, extrapolated while playing and kept within the track.
    public func position(at date: Date = Date()) -> Double {
        var value = elapsed
        if isPlaying { value += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        value = max(0, value)
        return duration > 0 ? min(value, duration) : value
    }
}

/// Playback commands, numbered the way the MediaRemote framework expects them.
public enum MediaCommand: Int, CaseIterable {
    case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
}

/// Repairs the position reported by players that only send it when a track
/// starts or is seeked. On pause or resume they repeat the old numbers, which
/// would make the time jump back; the position already reached is used instead.
public struct PositionTracker {
    private var previous: Track?
    private var lastReport: (elapsed: Double, timestamp: Date)?

    public init() {}

    public mutating func reset() {
        previous = nil
        lastReport = nil
    }

    public mutating func ingest(_ report: Track, now: Date = Date()) -> Track {
        var track = report
        let stale = lastReport.map { $0.elapsed == report.elapsed && $0.timestamp == report.timestamp } ?? false
        lastReport = (report.elapsed, report.timestamp)

        if stale, let previous, previous.id == track.id {
            if !track.isPlaying {
                // Paused, or still paused: freeze where playback actually stopped.
                track.elapsed = previous.position(at: now)
                track.timestamp = now
            } else if !previous.isPlaying {
                // Resumed: continue from the frozen position, not from the old report.
                track.elapsed = previous.elapsed
                track.timestamp = now
            } else {
                track.elapsed = previous.elapsed
                track.timestamp = previous.timestamp
            }
        }
        previous = track
        return track
    }

    /// The user moved the playhead; reports that still carry the old position must not undo it.
    public mutating func noteSeek(to seconds: Double, at now: Date = Date()) {
        previous?.elapsed = seconds
        previous?.timestamp = now
    }
}
