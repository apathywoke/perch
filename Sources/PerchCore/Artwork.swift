/// Decides which artwork to show for each message from the media helper.
///
/// Players such as Spotify briefly report the track without its artwork (after
/// a seek, a pause or a resume) and then send the same image again. Treating
/// that as new artwork made it flicker and flip. Artwork is therefore tracked
/// by its identifier, cached, and kept while the same song is playing.
public struct ArtworkTracker {
    public enum Action: Equatable {
        /// Show the image already decoded for this identifier.
        case show(String)
        /// Decode the image data that came with this message and show it.
        case decodeAndShow(String)
        /// Same song, artwork briefly missing: keep what is on screen.
        case keep
        /// No artwork for this song.
        case clear
        /// The image is not cached and was not sent: ask the helper to send it
        /// again, and keep what is on screen meanwhile (same song) or show nothing.
        case requestAndKeep(String)
        case requestAndClear(String)
    }

    /// Identifiers of decoded images, most recently used first.
    public private(set) var cachedIds: [String] = []
    /// What is on screen now.
    public private(set) var shownId: String?
    private var songId: String?
    private let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    public mutating func update(songId: String?, artworkId: String?, hasData: Bool) -> Action {
        let sameSong = songId != nil && songId == self.songId
        self.songId = songId
        guard songId != nil else {
            shownId = nil
            return .clear
        }
        guard let artworkId else {
            if sameSong { return .keep }
            shownId = nil
            return .clear
        }
        if cachedIds.contains(artworkId) {
            touch(artworkId)
            shownId = artworkId
            return .show(artworkId)
        }
        if hasData {
            touch(artworkId)
            shownId = artworkId
            return .decodeAndShow(artworkId)
        }
        if sameSong { return .requestAndKeep(artworkId) }
        shownId = nil
        return .requestAndClear(artworkId)
    }

    /// The data for `id` could not be decoded.
    public mutating func forget(_ id: String) {
        cachedIds.removeAll { $0 == id }
        if shownId == id { shownId = nil }
    }

    /// Nothing is known any more (the helper restarted). Cached images stay valid.
    public mutating func reset() {
        songId = nil
        shownId = nil
    }

    private mutating func touch(_ id: String) {
        cachedIds.removeAll { $0 == id }
        cachedIds.insert(id, at: 0)
        if cachedIds.count > capacity { cachedIds.removeLast(cachedIds.count - capacity) }
    }
}
