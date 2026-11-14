import Foundation
import Testing
@testable import PerchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite("Track position")
struct TrackPositionTests {
    @Test func extrapolatesWhilePlaying() {
        let track = Track(title: "A", duration: 200, elapsed: 10, timestamp: t0, isPlaying: true)
        #expect(track.position(at: t0.addingTimeInterval(5)) == 15)
    }

    @Test func honoursPlaybackRate() {
        let track = Track(title: "A", duration: 200, elapsed: 10, timestamp: t0, rate: 2, isPlaying: true)
        #expect(track.position(at: t0.addingTimeInterval(5)) == 20)
    }

    @Test func zeroRateWhilePlayingCountsAsNormalSpeed() {
        let track = Track(title: "A", duration: 200, elapsed: 10, timestamp: t0, rate: 0, isPlaying: true)
        #expect(track.position(at: t0.addingTimeInterval(5)) == 15)
    }

    @Test func staysPutWhilePaused() {
        let track = Track(title: "A", duration: 200, elapsed: 42, timestamp: t0, isPlaying: false)
        #expect(track.position(at: t0.addingTimeInterval(100)) == 42)
    }

    @Test func staysWithinTheTrack() {
        let ending = Track(title: "A", duration: 30, elapsed: 25, timestamp: t0, isPlaying: true)
        #expect(ending.position(at: t0.addingTimeInterval(10)) == 30)
        let early = Track(title: "A", duration: 30, elapsed: 0, timestamp: t0.addingTimeInterval(10), isPlaying: true)
        #expect(early.position(at: t0) == 0)
    }

    @Test func unknownDurationIsNotClamped() {
        let stream = Track(title: "Radio", duration: 0, elapsed: 500, timestamp: t0, isPlaying: true)
        #expect(stream.position(at: t0.addingTimeInterval(10)) == 510)
    }

    @Test func identityIgnoresPosition() {
        let a = Track(title: "Song", artist: "Artist", album: "Album", elapsed: 1)
        var b = a
        b.elapsed = 99
        b.isPlaying = true
        #expect(a.id == b.id)
        b.artist = "Someone else"
        #expect(a.id != b.id)
    }
}

/// Players such as Spotify report the position only when a track starts and
/// repeat those numbers on every pause and resume.
@Suite("Position tracker")
struct PositionTrackerTests {
    private let start = Track(title: "A", duration: 200, elapsed: 0, timestamp: t0, isPlaying: true)

    private func paused(_ track: Track) -> Track {
        var copy = track
        copy.isPlaying = false
        return copy
    }

    @Test func freshReportsPassThrough() {
        var tracker = PositionTracker()
        #expect(tracker.ingest(start, now: t0) == start)
    }

    @Test func pauseFreezesWherePlaybackStopped() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        let pauseTime = t0.addingTimeInterval(30)
        let result = tracker.ingest(paused(start), now: pauseTime)
        #expect(result.elapsed == 30)
        #expect(result.position(at: pauseTime.addingTimeInterval(100)) == 30)
    }

    @Test func resumeContinuesFromTheFrozenPosition() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        _ = tracker.ingest(paused(start), now: t0.addingTimeInterval(30))
        let resumeTime = t0.addingTimeInterval(100)
        let resumed = tracker.ingest(start, now: resumeTime)
        #expect(resumed.position(at: resumeTime.addingTimeInterval(10)) == 40)
    }

    @Test func repeatedReportsWhilePausedKeepThePosition() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        _ = tracker.ingest(paused(start), now: t0.addingTimeInterval(30))
        let again = tracker.ingest(paused(start), now: t0.addingTimeInterval(60))
        #expect(again.position(at: t0.addingTimeInterval(90)) == 30)
    }

    @Test func freshReportWinsOverTheEstimate() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        _ = tracker.ingest(paused(start), now: t0.addingTimeInterval(30))
        let fresh = Track(title: "A", duration: 200, elapsed: 28, timestamp: t0.addingTimeInterval(31), isPlaying: false)
        #expect(tracker.ingest(fresh, now: t0.addingTimeInterval(31)).elapsed == 28)
    }

    @Test func anotherSongIsNotTreatedAsStale() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        var other = start
        other.title = "B"
        #expect(tracker.ingest(other, now: t0.addingTimeInterval(30)) == other)
    }

    @Test func seekIsNotUndoneByAnOldReport() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        _ = tracker.ingest(paused(start), now: t0.addingTimeInterval(30))
        tracker.noteSeek(to: 120, at: t0.addingTimeInterval(40))
        let after = tracker.ingest(paused(start), now: t0.addingTimeInterval(50))
        #expect(after.elapsed == 120)
    }

    @Test func resetForgetsHistory() {
        var tracker = PositionTracker()
        _ = tracker.ingest(start, now: t0)
        tracker.reset()
        #expect(tracker.ingest(paused(start), now: t0.addingTimeInterval(30)).elapsed == 0)
    }
}
