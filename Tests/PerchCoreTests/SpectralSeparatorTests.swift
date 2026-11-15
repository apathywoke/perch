import Foundation
import Testing
@testable import PerchCore

@Suite("Neural voice separation: the signal side")
struct SpectralSeparatorTests {
    /// Something to feed: noise in both channels, different in each.
    private func sound(_ count: Int, seed: UInt64 = 1) -> (left: [Float], right: [Float]) {
        var state = seed
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 4000
        }
        return ((0..<count).map { _ in next() }, (0..<count).map { _ in next() })
    }

    /// Feeds the sound in uneven pieces, then flushes; returns all output and checks it is contiguous.
    private func separate(_ separator: SpectralSeparator, _ input: (left: [Float], right: [Float]),
                          startingAt start: Int = 0, masker: SpectralSeparator.Masker) -> [Float] {
        var output: [Float] = []
        var offset = 0
        var piece = 300
        while offset < input.left.count {
            let end = min(input.left.count, offset + piece)
            let (samples, first) = separator.process(left: Array(input.left[offset..<end]),
                                                     right: Array(input.right[offset..<end]), masker: masker)
            if !samples.isEmpty { #expect(first == start + output.count) }
            output += samples
            offset = end
            piece = piece * 7 % 5000 + 100
        }
        let (rest, first) = separator.flush(masker: masker)
        if !rest.isEmpty { #expect(first == start + output.count) }
        return output + rest
    }

    /// Away from the ends of the stream.
    private func worstDifference(_ a: [Float], _ b: [Float]) -> Float {
        let edge = SpectralSeparator.size
        return (edge..<min(a.count, b.count) - edge).map { abs(a[$0] - b[$0]) }.max() ?? .infinity
    }

    private func constant(_ value: Float) -> SpectralSeparator.Masker {
        { magnitudes in [Float](repeating: value, count: magnitudes.count) }
    }

    @Test func aFullMaskGivesBackTheSoundInMono() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let input = sound(44100 * 3)
        let output = separate(separator, input, masker: constant(1))
        #expect(output.count == input.left.count)
        // The mask covers frequencies up to 11 kHz; noise above that is gone, so compare
        // with a lenient bound on the whole and check the level matches.
        let mono = zip(input.left, input.right).map { ($0 + $1) / 2 }
        let error = zip(output, mono).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        let power = mono.map { $0 * $0 }.reduce(0, +)
        #expect(error / power < 0.6)
        let outPower = output.map { $0 * $0 }.reduce(0, +)
        #expect(outPower > 0.3 * power && outPower < 1.05 * power)
    }

    @Test func lowSoundComesBackExactly() {
        // A tone well under 11 kHz passes the full mask untouched, sample for sample
        // (except where it starts and stops abruptly, which sounds above 11 kHz too).
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let count = 44100 * 2
        let left = (0..<count).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44100)) * 0.5 }
        let right = (0..<count).map { Float(sin(2 * Double.pi * 660 * Double($0) / 44100)) * 0.3 }
        let output = separate(separator, (left, right), masker: constant(1))
        #expect(output.count == count)
        let mono = zip(left, right).map { ($0 + $1) / 2 }
        #expect(worstDifference(output, mono) < 1e-4)
    }

    @Test func anEmptyMaskGivesSilence() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let output = separate(separator, sound(44100), masker: constant(0))
        #expect(output.count == 44100)
        #expect(output.allSatisfy { abs($0) < 1e-6 })
    }

    @Test func eachChannelHasItsOwnMask() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let count = 44100 * 2
        let left = (0..<count).map { Float(sin(2 * Double.pi * 300 * Double($0) / 44100)) }
        let right = (0..<count).map { Float(sin(2 * Double.pi * 500 * Double($0) / 44100)) }
        let frames = separator.frames, bins = SpectralSeparator.bins
        // Keep the left channel, drop the right.
        let output = separate(separator, (left, right)) { magnitudes in
            (0..<magnitudes.count).map { $0 < frames * bins ? 1 : 0 }
        }
        #expect(worstDifference(output, left.map { $0 / 2 }) < 1e-4)
    }

    @Test func magnitudesAreOnSpleetersScale() {
        // TensorFlow's STFT: a full-scale sine under a 4096-sample Hann window peaks at 4096 / 4.
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let bin = 40
        let frequency = Double(bin) * 44100 / 4096
        let tone = (0..<44100 * 3).map { Float(sin(2 * Double.pi * frequency * Double($0) / 44100)) }
        var peak: Float = 0
        _ = separator.process(left: tone, right: tone) { magnitudes in
            peak = max(peak, magnitudes[20 * SpectralSeparator.bins + bin])
            return magnitudes.map { _ in 1 }
        }
        #expect(abs(peak - 1024) < 2)
    }

    @Test func runsOverlapAndHoldOnlyAFewSeconds() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        var runs = 0
        let seconds = 10
        let output = separate(separator, sound(44100 * seconds)) { magnitudes in
            runs += 1
            #expect(magnitudes.count == 2 * 64 * SpectralSeparator.bins)
            return magnitudes.map { _ in 1 }
        }
        #expect(output.count == 44100 * seconds)
        // 10 s is 434 frames; each run but the first decides 48 new ones.
        #expect(runs == 9 || runs == 10)
        #expect(separator.latency < 2)
    }

    @Test func aFlushStartsANewStreamWhereTheLastEnded() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let first = separate(separator, sound(30000), masker: constant(1))
        #expect(first.count == 30000)
        let second = separate(separator, sound(20000, seed: 2), startingAt: 30000, masker: constant(1))
        #expect(second.count == 20000)
    }

    @Test func aResetDropsWhatWasHeld() {
        let separator = SpectralSeparator(frames: 64, margin: 8)
        let input = sound(10000)
        _ = separator.process(left: input.left, right: input.right, masker: constant(1))
        separator.reset()
        let (samples, first) = separator.flush(masker: constant(1))
        #expect(samples.isEmpty)
        #expect(first == 10000)
    }

    @Test func ratioMaskFollowsSpleeter() {
        let mask = SpectralSeparator.ratioMask(vocals: [1, 0, 0.5, 0, 0.3], accompaniment: [0, 1, 0.5, 0, 0.4])
        #expect(abs(mask[0] - 1) < 1e-4)
        #expect(abs(mask[1]) < 1e-4)
        #expect(abs(mask[2] - 0.5) < 1e-4)
        #expect(abs(mask[3] - 0.5) < 1e-4)
        #expect(abs(mask[4] - 0.09 / 0.25) < 1e-4)
    }
}
