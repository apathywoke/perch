import Testing
@testable import PerchCore

@Suite("Artwork")
struct ArtworkTrackerTests {
    @Test func newSongWithArtworkIsDecoded() {
        var tracker = ArtworkTracker()
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: true) == .decodeAndShow("x"))
        #expect(tracker.shownId == "x")
    }

    /// The case behind the flipping artwork: Spotify after a seek.
    @Test func briefGapAfterASeekKeepsTheArtwork() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        #expect(tracker.update(songId: "A", artworkId: nil, hasData: false) == .keep)
        #expect(tracker.shownId == "x")
        // The same image arrives again: shown from the cache, not decoded and not flipped.
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: true) == .show("x"))
        #expect(tracker.shownId == "x")
    }

    @Test func newSongWithoutArtworkClears() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        #expect(tracker.update(songId: "B", artworkId: nil, hasData: false) == .clear)
        #expect(tracker.shownId == nil)
    }

    @Test func returningSongUsesTheCache() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        _ = tracker.update(songId: "B", artworkId: "y", hasData: true)
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: false) == .show("x"))
    }

    @Test func missingImageIsRequestedAgain() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        #expect(tracker.update(songId: "A", artworkId: "z", hasData: false) == .requestAndKeep("z"))
        #expect(tracker.shownId == "x")
        #expect(tracker.update(songId: "B", artworkId: "w", hasData: false) == .requestAndClear("w"))
        #expect(tracker.shownId == nil)
    }

    @Test func cacheForgetsTheOldestImage() {
        var tracker = ArtworkTracker(capacity: 2)
        _ = tracker.update(songId: "A", artworkId: "a", hasData: true)
        _ = tracker.update(songId: "B", artworkId: "b", hasData: true)
        _ = tracker.update(songId: "C", artworkId: "c", hasData: true)
        #expect(tracker.cachedIds == ["c", "b"])
        #expect(tracker.update(songId: "A", artworkId: "a", hasData: false) == .requestAndClear("a"))
    }

    @Test func undecodableImageIsForgotten() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        tracker.forget("x")
        #expect(tracker.shownId == nil)
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: false) == .requestAndKeep("x"))
    }

    @Test func nothingPlayingClears() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        #expect(tracker.update(songId: nil, artworkId: nil, hasData: false) == .clear)
        // After a gap with nothing playing, the same song is a fresh start, but the image is still cached.
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: false) == .show("x"))
    }

    @Test func resetForgetsTheSongButNotTheImages() {
        var tracker = ArtworkTracker()
        _ = tracker.update(songId: "A", artworkId: "x", hasData: true)
        tracker.reset()
        #expect(tracker.shownId == nil)
        #expect(tracker.update(songId: "A", artworkId: nil, hasData: false) == .clear)
        #expect(tracker.update(songId: "A", artworkId: "x", hasData: false) == .show("x"))
    }
}
