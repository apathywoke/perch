import Foundation

public struct LyricLine: Equatable, Identifiable {
    public let id: Int
    /// Start of the line, in seconds from the beginning of the song.
    public let time: Double
    /// Empty for an instrumental break.
    public let text: String

    public init(id: Int, time: Double, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

public enum Lyrics: Equatable {
    /// Lines with timestamps: the current one can be highlighted.
    case synced([LyricLine])
    /// Text without timing.
    case plain([String])
    case instrumental
}

// MARK: - LRC

/// Reads the LRC format: `[mm:ss.xx]text`, several stamps per line allowed,
/// `[offset:±ms]` honoured, other tags (`[ar:…]`, `[ti:…]`) ignored.
public enum LRCParser {
    public static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var stamped: [(time: Double, order: Int, text: String)] = []
        var order = 0
        for rawLine in text.components(separatedBy: .newlines) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                line = line[line.index(after: close)...]
            }
            let words = line.trimmingCharacters(in: .whitespaces)
            for time in times {
                stamped.append((time, order, words))
                order += 1
            }
        }
        // A positive offset makes the lyrics appear sooner.
        return stamped
            .sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: max(0, $0.element.time - offset), text: $0.element.text) }
    }

    /// "01:02.34", "1:02", "01:02:340" → seconds.
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              parts[0].allSatisfy(\.isNumber) else { return nil }
        let rest = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(rest), seconds >= 0, seconds < 60,
              rest.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }
}

// MARK: - Timing

public enum LyricsTiming {
    /// The line being sung at `position`; nil before the first one.
    public static func currentIndex(in lines: [LyricLine], at position: Double) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// Start times of the lines still to come, as seconds from `position`.
    public static func upcoming(in lines: [LyricLine], after position: Double) -> [Double] {
        lines.lazy.filter { $0.time > position }.map { $0.time - position }
    }
}

// MARK: - LRCLIB

/// Requests to lrclib.net, a free, open lyrics database.
public enum LRCLIB {
    public static let host = "lrclib.net"

    /// Exact lookup; needs the album and the length.
    public static func getURL(title: String, artist: String, album: String, duration: Double) -> URL? {
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty, duration > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/get"
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        return components.url
    }

    public static func searchURL(title: String, artist: String) -> URL? {
        guard !title.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/search"
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
            + (artist.isEmpty ? [] : [URLQueryItem(name: "artist_name", value: artist)])
        return components.url
    }

    /// One record from /api/get or /api/search.
    public static func lyrics(from record: [String: Any]) -> Lyrics? {
        if let synced = record["syncedLyrics"] as? String {
            let lines = LRCParser.parse(synced)
            if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
        }
        if let plain = record["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if record["instrumental"] as? Bool == true { return .instrumental }
        return nil
    }

    public static func parseGet(_ data: Data) -> Lyrics? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lyrics(from: record)
    }

    /// Picks the best search result: synced over plain, then the closest length.
    public static func parseSearch(_ data: Data, duration: Double) -> Lyrics? {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func distance(_ record: [String: Any]) -> Double {
            guard duration > 0, let length = number(record["duration"]) else { return 0 }
            return abs(length - duration)
        }
        let candidates = records
            .filter { duration <= 0 || distance($0) <= 5 } // a different recording is worse than nothing
            .compactMap { record in lyrics(from: record).map { (lyrics: $0, distance: distance(record)) } }
        func rank(_ lyrics: Lyrics) -> Int {
            switch lyrics {
            case .synced: 0
            case .plain: 1
            case .instrumental: 2
            }
        }
        return candidates.min {
            (rank($0.lyrics), $0.distance) < (rank($1.lyrics), $1.distance)
        }?.lyrics
    }
}
