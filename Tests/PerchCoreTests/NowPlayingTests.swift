import Foundation
import Testing
@testable import PerchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite("Media helper messages")
struct NowPlayingParserTests {
    @Test func parsesAFullMessage() throws {
        let line = #"{"title":"Song","artist":"Artist","album":"Album","bundleId":"com.spotify.client","playing":true,"duration":215.5,"elapsed":12.25,"timestamp":1000000,"rate":1,"artworkId":"5-abc","artwork":"aGVsbG8="}"#
        let update = try #require(NowPlayingParser.parse(Data(line.utf8)))
        let track = try #require(update.track)
        #expect(track.title == "Song")
        #expect(track.artist == "Artist")
        #expect(track.album == "Album")
        #expect(track.bundleId == "com.spotify.client")
        #expect(track.isPlaying)
        #expect(track.duration == 215.5)
        #expect(track.elapsed == 12.25)
        #expect(track.timestamp == t0)
        #expect(update.artworkId == "5-abc")
        #expect(update.artworkData == Data("hello".utf8))
    }

    @Test func emptyObjectMeansNothingIsPlaying() throws {
        let update = try #require(NowPlayingParser.parse(Data("{}".utf8)))
        #expect(update.track == nil)
    }

    @Test func emptyTitleMeansNothingIsPlaying() throws {
        let update = try #require(NowPlayingParser.parse(Data(#"{"title":"","playing":true}"#.utf8)))
        #expect(update.track == nil)
    }

    @Test func missingFieldsGetDefaults() throws {
        let update = try #require(NowPlayingParser.parse(Data(#"{"title":"Only"}"#.utf8), now: t0))
        let track = try #require(update.track)
        #expect(track.artist.isEmpty)
        #expect(track.duration == 0)
        #expect(track.rate == 1)
        #expect(!track.isPlaying)
        #expect(track.timestamp == t0)
        #expect(update.artworkId == nil)
    }

    @Test func integerNumbersAreAccepted() throws {
        let update = try #require(NowPlayingParser.parse(Data(#"{"title":"A","duration":215,"elapsed":3}"#.utf8)))
        #expect(update.track?.duration == 215)
        #expect(update.track?.elapsed == 3)
    }

    @Test(arguments: ["not json", "[1,2]", "", "\"text\""])
    func ignoresAnythingButAnObject(line: String) {
        #expect(NowPlayingParser.parse(Data(line.utf8)) == nil)
    }
}

@Suite("Backup source")
struct FallbackParserTests {
    @Test func spotifyReportsThePosition() throws {
        let info: [AnyHashable: Any] = [
            "Name": "Song", "Artist": "Artist", "Album": "Album", "Player State": "Playing",
            "Duration": NSNumber(value: 215_000), "Playback Position": NSNumber(value: 12.5),
        ]
        let report = FallbackParser.parse(info, player: .spotify, now: t0)
        let track = try #require(report.track)
        #expect(report.positionKnown)
        #expect(track.duration == 215)
        #expect(track.elapsed == 12.5)
        #expect(track.isPlaying)
        #expect(track.bundleId == "com.spotify.client")
    }

    @Test func musicDoesNotReportThePosition() throws {
        let info: [AnyHashable: Any] = [
            "Name": "Song", "Artist": "Artist", "Player State": "Paused", "Total Time": NSNumber(value: 180_000),
        ]
        let report = FallbackParser.parse(info, player: .music, now: t0)
        let track = try #require(report.track)
        #expect(!report.positionKnown)
        #expect(track.duration == 180)
        #expect(!track.isPlaying)
        #expect(track.bundleId == "com.apple.Music")
    }

    @Test(arguments: [
        ["Name": "Song", "Player State": "Stopped"],
        ["Player State": "Playing"],
        ["Name": "", "Player State": "Playing"],
        [:],
    ] as [[String: String]])
    func stoppedOrIncompleteMeansNothing(info: [String: String]) {
        #expect(FallbackParser.parse(info, player: .music).track == nil)
    }

    @Test func sameSongContinuesTheEstimate() {
        let previous = Track(title: "Song", artist: "A", bundleId: "com.apple.Music", duration: 180,
                             elapsed: 10, timestamp: t0, isPlaying: true)
        let report = FallbackParser.parse(["Name": "Song", "Artist": "A", "Player State": "Paused",
                                           "Total Time": NSNumber(value: 180_000)], player: .music)
        let merged = FallbackParser.merge(report, previous: previous, now: t0.addingTimeInterval(20))
        #expect(merged?.elapsed == 30)
        #expect(merged?.timestamp == t0.addingTimeInterval(20))
    }

    @Test func newSongStartsAtZero() {
        let previous = Track(title: "Old", bundleId: "com.apple.Music", elapsed: 100, timestamp: t0, isPlaying: true)
        let report = FallbackParser.parse(["Name": "New", "Player State": "Playing"], player: .music)
        #expect(FallbackParser.merge(report, previous: previous, now: t0.addingTimeInterval(5))?.elapsed == 0)
    }

    @Test func reportedPositionIsKept() {
        let report = FallbackParser.parse(["Name": "Song", "Player State": "Playing",
                                           "Playback Position": NSNumber(value: 42)], player: .spotify)
        #expect(FallbackParser.merge(report, previous: nil)?.elapsed == 42)
    }
}

@Suite("Choosing the source")
struct SourceSelectorTests {
    private let spotify = Track(title: "S", bundleId: "com.spotify.client", isPlaying: true)
    private let musicPaused = Track(title: "M", bundleId: "com.apple.Music", isPlaying: false)
    private let browser = Track(title: "B", bundleId: "com.google.Chrome", isPlaying: true)

    @Test func systemServiceWins() {
        let result = SourceSelector.select(primary: browser, primaryAvailable: true, fallback: [spotify], ignored: [])
        #expect(result.track == browser)
        #expect(result.source == .system)
    }

    @Test func backupTakesOverWhenTheServiceIsUnavailable() {
        let result = SourceSelector.select(primary: nil, primaryAvailable: false, fallback: [musicPaused], ignored: [])
        #expect(result.track == musicPaused)
        #expect(result.source == .fallback(.music))
    }

    @Test func whileTheServiceWorksOnlyPlayingBackupTracksCount() {
        let paused = SourceSelector.select(primary: nil, primaryAvailable: true, fallback: [musicPaused], ignored: [])
        #expect(paused.track == nil)
        #expect(paused.source == .none)
        let playing = SourceSelector.select(primary: nil, primaryAvailable: true, fallback: [spotify], ignored: [])
        #expect(playing.source == .fallback(.spotify))
    }

    @Test func playingBeatsPaused() {
        let result = SourceSelector.select(primary: nil, primaryAvailable: false, fallback: [musicPaused, spotify], ignored: [])
        #expect(result.track == spotify)
    }

    @Test func ignoredAppsStayHiddenInBothSources() {
        let result = SourceSelector.select(primary: spotify, primaryAvailable: true, fallback: [spotify],
                                           ignored: ["com.spotify.client"])
        #expect(result.track == nil)
        #expect(result.source == .none)
    }

    @Test func ignoringTheBrowserLetsAPlayerThrough() {
        let result = SourceSelector.select(primary: browser, primaryAvailable: true, fallback: [spotify],
                                           ignored: ["com.google.Chrome"])
        #expect(result.track == spotify)
    }
}
