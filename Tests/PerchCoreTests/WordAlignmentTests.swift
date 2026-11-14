import Foundation
import Testing
@testable import PerchCore

@Suite("Word alignment")
struct WordAlignmentTests {
    private let lines = LRCParser.parse("""
    [00:10.00]Hello darkness my old friend
    [00:15.00]I've come to talk with you again
    [00:20.00]
    [00:24.00]Because a vision softly creeping
    """)

    private func heard(_ text: String, _ start: Double, _ length: Double = 0.4) -> HeardWord {
        HeardWord(text: text, start: start, end: start + length)
    }

    @Test func normalizesWords() {
        #expect(WordAlignment.normalize("Don't,") == "dont")
        #expect(WordAlignment.normalize("Café!") == "cafe")
        #expect(WordAlignment.normalize("ПРИВЕТ…") == "привет")
        #expect(WordAlignment.normalize("•").isEmpty)
    }

    @Test func similarityToleratesSmallSlips() {
        #expect(WordAlignment.similarity("darkness", "darkness") == 1)
        #expect(WordAlignment.similarity("creeping", "creepin") > 0.8)
        #expect(WordAlignment.similarity("friend", "vision") < 0.5)
    }

    @Test func heardWordsTakeTheirRealTimes() {
        let words = [heard("hello", 10.6), heard("darkness", 11.3, 0.7), heard("my", 12.4, 0.2),
                     heard("old", 12.7), heard("friend", 13.3, 0.9)]
        let aligned = WordAlignment.align(lines, heard: words)
        #expect(aligned[0].words.map(\.start) == [10.6, 11.3, 12.4, 12.7, 13.3])
        #expect(abs(aligned[0].words.last!.end - 14.2) < 0.0001)
        #expect(aligned[0].heard == 5)
        // Nothing heard in the next line: it moves with this one, 0.6 s later.
        #expect(aligned[1].heard == 0)
        #expect(abs(aligned[1].time - 15.6) < 0.0001)
        #expect(aligned[1].text == lines[1].text)
    }

    @Test func wordsInBetweenAreSpreadOverTheGap() {
        let words = [heard("hello", 10.5), heard("friend", 13.5)]
        let line = WordAlignment.align(lines, heard: words)[0]
        let middle = line.words[1...3]
        #expect(middle.first!.start == 10.9)
        #expect(abs(middle.last!.end - 13.5) < 0.0001)
        #expect(zip(middle, middle.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 })
    }

    @Test func farAwayWordsAreNotMatched() {
        // "friend" sung 20 s later belongs to another place in the song.
        let aligned = WordAlignment.align(lines, heard: [heard("friend", 33)])
        #expect(aligned == lines)
    }

    @Test func shortWordsMustBeCloseAndExact() {
        let line = WordAlignment.align(lines, heard: [heard("my", 14.5)])[0]
        #expect(line.heard == 0)
        let close = WordAlignment.align(lines, heard: [heard("my", 11.9)])[0]
        #expect(close.heard == 1)
    }

    @Test func lineComesUpForAnEarlyFirstWord() {
        let aligned = WordAlignment.align(lines, heard: [heard("I've", 14.6), heard("come", 14.9)])
        #expect(aligned[1].time <= 14.6 && aligned[1].time > 14.4)
        #expect(aligned[1].words[0].start == 14.6)
    }

    @Test func breaksMoveWithTheNextLine() {
        let aligned = WordAlignment.align(lines, heard: [heard("because", 24.3), heard("vision", 25.2)])
        #expect(aligned[3].words[0].start == 24.3)
        let shift = aligned[2].time - lines[2].time
        #expect(shift > 0.1 && shift < 0.4)
        #expect(aligned[2].words.map(\.text) == ["•", "•", "•"])
        #expect(zip(aligned, aligned.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func unheardLinesFollowALateFile() {
        // The file is 1.5 s late all along; the middle line was not recognised.
        let song = LRCParser.parse("""
        [00:10.00]Walking down the empty street
        [00:14.00]Lights are burning everywhere
        [00:18.00]Nobody remembers anything
        """)
        let expected = song.flatMap(\.words).map(\.start)
        let words = [heard("walking", expected[0] - 1.5), heard("empty", expected[3] - 1.5),
                     heard("street", expected[4] - 1.5), heard("nobody", expected[9] - 1.5),
                     heard("remembers", expected[10] - 1.5), heard("anything", expected[11] - 1.5)]
        let aligned = WordAlignment.align(song, heard: words)
        #expect(aligned[1].heard == 0)
        #expect(abs(aligned[1].time - 12.5) < 0.2)
        #expect(abs(aligned[1].words[0].start - aligned[1].time) < 0.0001)
    }

    @Test func shortWordsMatchOnceTheOffsetIsKnown() {
        // "to" is 1.6 s from where the file puts it: too far on its own, fine once
        // the long words show the file is that late.
        let song = LRCParser.parse("[00:10.00]Talk to someone tonight")
        let words = [heard("talk", 8.4), heard("to", 8.8), heard("someone", 9.1), heard("tonight", 9.8)]
        let aligned = WordAlignment.align(song, heard: words)
        #expect(aligned[0].heard == 4)
    }

    @Test func repeatedWordsKeepTheirOrder() {
        let chorus = LRCParser.parse("[00:10.00]na na na na\n[00:13.00]hey hey goodbye")
        let words = [heard("na", 10.2), heard("na", 10.7), heard("na", 11.2), heard("na", 11.7),
                     heard("hey", 13.4), heard("hey", 13.9), heard("goodbye", 14.4)]
        let aligned = WordAlignment.align(chorus, heard: words)
        #expect(aligned[0].words.map(\.start) == [10.2, 10.7, 11.2, 11.7])
        #expect(aligned[1].words.map(\.start) == [13.4, 13.9, 14.4])
    }

    @Test func exactlyTimedLinesStayAsTheyAre() {
        let exact = LRCParser.parse("[00:10.00]<00:10.00>Hello <00:10.80>world<00:11.50>")
        #expect(WordAlignment.align(exact, heard: [heard("hello", 10.3)]) == exact)
    }

    @Test func listenedStretchesMerge() {
        var transcript = HeardTranscript()
        transcript.listen(from: 10, to: 20)
        transcript.listen(from: 30, to: 40)
        transcript.listen(from: 18, to: 32)
        #expect(transcript.listened == [HeardTranscript.Span(start: 10, end: 40)])
        #expect(transcript.coverage(from: 0, to: 40) == 0.75)
        transcript.listen(from: 50, to: 60)
        #expect(transcript.coverage(from: 35, to: 55) == 0.5)
    }

    @Test func oldFilesWithoutListenedStretchesStillLoad() throws {
        let data = Data(#"{"words":[{"text":"hi","start":1,"end":1.5}]}"#.utf8)
        let transcript = try JSONDecoder().decode(HeardTranscript.self, from: data)
        #expect(transcript.words.count == 1)
        #expect(transcript.listened.isEmpty)
    }

    @Test func aWordHeardInTheWrongPlaceIsIgnored() {
        // The file is 1 s late; "friend" was misheard 2.5 s away from the rest.
        let expected = lines[0].words.map(\.start)
        let words = [heard("hello", expected[0] - 1), heard("darkness", expected[1] - 1),
                     heard("my", expected[2] - 1), heard("old", expected[3] - 1),
                     heard("friend", expected[4] + 1.5)]
        let line = WordAlignment.align(lines, heard: words)[0]
        #expect(line.heard == 4)
        #expect(abs(line.words[4].start - (expected[4] - 1)) < 0.5)
    }

    @Test func farAwayLinesKeepTheFileTiming() {
        // Heard only at the start of a long song: the end stays as the file has it.
        let text = (0..<12).map { String(format: "[00:%02d.00]line number %d goes on and on", $0 * 4 + 10, $0) }
        let song = LRCParser.parse(text.joined(separator: "\n"))
        let expected = song[0].words.map(\.start)
        let words = zip(song[0].words, expected).map { heard($0.text, $1 - 1.5) }
        let aligned = WordAlignment.align(song, heard: words)
        #expect(abs(aligned[1].time - (song[1].time - 1.5)) < 0.01) // a neighbour moves along
        #expect(aligned[11] == song[11]) // forty words away does not
    }

    @Test func newResultsReplaceWhatTheyCover() {
        var transcript = HeardTranscript()
        transcript.replace(from: 10, to: 12, with: [heard("hello", 10.2), heard("darknes", 11)])
        transcript.replace(from: 13, to: 14, with: [heard("friend", 13.3)])
        transcript.replace(from: 10, to: 12, with: [heard("hello", 10.2), heard("darkness", 11)])
        #expect(transcript.words.map(\.text) == ["hello", "darkness", "friend"])
    }
}
