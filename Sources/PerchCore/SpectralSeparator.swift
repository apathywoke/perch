import Accelerate
import Foundation

/// The signal side of neural voice separation, as a stream: sound in, the
/// voice alone out, a few seconds later.
///
/// Stereo sound at 44.1 kHz is cut into overlapping frames (4096 samples, a
/// Hann window every 1024 samples), as Spleeter was trained on. The magnitudes
/// of the lowest 1024 frequencies (up to 11 kHz) go to a `Masker` in runs of
/// `frames` frames; it says how much of each one is voice. The masked frames of
/// both channels are added up into mono sound again.
///
/// A network sees best in the middle of what it is given, so runs overlap:
/// `margin` frames at each end of a run are only context, taken from the
/// runs either side. Every sample out has an index counted in the samples fed
/// so far, so the caller can tell where in the song it belongs.
public final class SpectralSeparator {
    /// How much of each frequency of each frame is voice, from 0 to 1.
    /// Takes and returns `[channel][frame][bin]` flattened: 2 × frames × `bins`.
    public typealias Masker = (_ magnitudes: [Float]) -> [Float]?

    public static let sampleRate = 44100.0
    public static let size = 4096
    public static let hop = 1024
    public static let bins = 1024

    public let frames: Int
    public let margin: Int

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    /// Sound not yet cut into frames.
    private var left: [Float] = []
    private var right: [Float] = []
    /// Spectra of frames not yet added to the sound, and the margin before them.
    /// Frame i of a stream covers its samples (i - 3) × hop ..< (i + 1) × hop.
    private var spectra: [Frame] = []
    /// The first run of a stream has no frames before it, so it keeps its start.
    private var firstRun = true
    /// Sound being added up from masked frames; its first sample is `outputStart`.
    private var accumulator: [Float]
    private var outputStart = 0
    /// Where this stream began, in samples fed: the output starts there.
    private var origin = 0
    private var fed = 0

    private struct Frame {
        var left: Spectrum
        var right: Spectrum
    }

    /// The lowest `bins` frequencies only: the mask leaves out the rest.
    private struct Spectrum {
        var real: [Float]
        var imag: [Float]
    }

    public init(frames: Int = 512, margin: Int = 64) {
        precondition(frames > 2 * margin && margin >= 0)
        self.frames = frames
        self.margin = margin
        let size = Self.size
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
        // Periodic Hann, as TensorFlow's STFT in Spleeter.
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        accumulator = [Float](repeating: 0, count: size)
        startStream()
    }

    /// Seconds of sound the separator holds before it gives it back, at most.
    public var latency: Double { Double((frames - margin + 3) * Self.hop) / Self.sampleRate }

    private func startStream() {
        // Three hops of silence before the first sample, so that it is covered by four frames like the rest.
        left = [Float](repeating: 0, count: Self.size - Self.hop)
        right = left
        origin = fed
        spectra = []
        firstRun = true
        accumulator = [Float](repeating: 0, count: Self.size)
        outputStart = fed - (Self.size - Self.hop)
    }

    /// Adds stereo sound and returns the voice that is ready, with the index of its first sample.
    public func process(left newLeft: [Float], right newRight: [Float], masker: Masker) -> (samples: [Float], firstIndex: Int) {
        left.append(contentsOf: newLeft)
        right.append(contentsOf: newRight)
        fed += newLeft.count
        cutFrames()
        var output: [Float] = []
        let first = max(outputStart, origin)
        while spectra.count >= frames {
            output.append(contentsOf: run(masker, final: false))
        }
        return (output, first)
    }

    /// Gives back everything still held, with the index of its first sample, and starts afresh
    /// (after a pause or a seek, what comes next belongs elsewhere in the song).
    public func flush(masker: Masker) -> (samples: [Float], firstIndex: Int) {
        let end = fed
        // Enough silence for the last real sample to be covered by four frames.
        let padding = Self.size
        left.append(contentsOf: repeatElement(0, count: padding))
        right.append(contentsOf: repeatElement(0, count: padding))
        cutFrames()
        let first = max(outputStart, origin)
        var output: [Float] = []
        while !spectra.isEmpty {
            output.append(contentsOf: run(masker, final: true))
        }
        let wanted = max(0, end - first)
        if output.count > wanted { output.removeLast(output.count - wanted) }
        startStream()
        return (output, first)
    }

    /// Drops what is held without giving it back, and starts afresh.
    public func reset() {
        startStream()
    }

    // MARK: Frames

    private func cutFrames() {
        let size = Self.size, hop = Self.hop
        var offset = 0
        while left.count - offset >= size {
            let l = spectrum(Array(left[offset..<offset + size]))
            let r = spectrum(Array(right[offset..<offset + size]))
            spectra.append(Frame(left: l, right: r))
            offset += hop
        }
        if offset > 0 {
            left.removeFirst(offset)
            right.removeFirst(offset)
        }
    }

    /// Masks one run of frames and returns the sound that became complete.
    private func run(_ masker: Masker, final: Bool) -> [Float] {
        let bins = Self.bins
        let available = min(frames, spectra.count)
        var magnitudes = [Float](repeating: 0, count: 2 * frames * bins)
        magnitudes.withUnsafeMutableBufferPointer { pointer in
            for index in 0..<available {
                let frame = spectra[index]
                for (channel, spectrum) in [frame.left, frame.right].enumerated() {
                    // vDSP's real FFT gives twice the textbook value.
                    let magnitude = vDSP.multiply(0.5, vDSP.hypot(spectrum.real, spectrum.imag))
                    let base = (channel * frames + index) * bins
                    magnitude.withUnsafeBufferPointer { pointer.baseAddress!.advanced(by: base).update(from: $0.baseAddress!, count: bins) }
                }
            }
        }
        // Without a mask (the network failed), the sound goes through as it is.
        let mask = masker(magnitudes)
        // Frames this run decides: from its start (first run) or after the margin,
        // up to the margin before its end (or all, when nothing follows).
        let from = firstRun ? 0 : margin
        let to = final && spectra.count <= frames ? available : min(available, frames - margin)
        var output: [Float] = []
        for index in from..<to {
            output.append(contentsOf: addFrame(spectra[index], mask: mask, at: index))
        }
        // Keep the margin before the next run's first decided frame as its context.
        let next = to - margin
        if to >= available && final {
            spectra.removeAll()
        } else {
            spectra.removeFirst(max(0, next))
        }
        firstRun = false
        return output
    }

    /// Adds one masked frame to the sound and returns the samples it completed.
    private func addFrame(_ frame: Frame, mask: [Float]?, at index: Int) -> [Float] {
        let size = Self.size, hop = Self.hop, half = size / 2, bins = Self.bins
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        for bin in 0..<bins {
            let l = mask.map { $0[index * bins + bin] } ?? 1
            let r = mask.map { $0[(frames + index) * bins + bin] } ?? 1
            real[bin] = 0.5 * (l * frame.left.real[bin] + r * frame.right.real[bin])
            imag[bin] = 0.5 * (l * frame.left.imag[bin] + r * frame.right.imag[bin])
        }
        // Bin 0's imaginary slot holds the highest frequency, which the mask leaves out.
        imag[0] = 0
        let samples = vDSP.multiply(window, signal(real, imag))
        vDSP.add(accumulator, samples, result: &accumulator)
        // Hann windows a quarter apart, applied twice, add up to 1.5.
        let done = vDSP.multiply(1 / 1.5, Array(accumulator[0..<hop]))
        accumulator.removeFirst(hop)
        accumulator.append(contentsOf: repeatElement(0, count: hop))
        let start = outputStart
        outputStart += hop
        // Samples before the stream began are only the silence put there.
        let skip = min(hop, max(0, origin - start))
        return Array(done[skip...])
    }

    // MARK: FFT

    /// Real FFT of a windowed frame, in vDSP's packed form (twice the textbook values).
    private func spectrum(_ samples: [Float]) -> Spectrum {
        let half = Self.size / 2
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var outReal = [Float](repeating: 0, count: half), outImag = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                outReal.withUnsafeMutableBufferPointer { outRealPointer in
                    outImag.withUnsafeMutableBufferPointer { outImagPointer in
                        var out = DSPSplitComplex(realp: outRealPointer.baseAddress!, imagp: outImagPointer.baseAddress!)
                        fft.forward(input: split, output: &out)
                    }
                }
            }
        }
        return Spectrum(real: Array(outReal[0..<Self.bins]), imag: Array(outImag[0..<Self.bins]))
    }

    /// The inverse of `spectrum`, back at the original level.
    private func signal(_ real: [Float], _ imag: [Float]) -> [Float] {
        let size = Self.size, half = size / 2
        var real = real, imag = imag
        var samples = [Float](repeating: 0, count: size)
        var outReal = [Float](repeating: 0, count: half), outImag = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                let split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                outReal.withUnsafeMutableBufferPointer { outRealPointer in
                    outImag.withUnsafeMutableBufferPointer { outImagPointer in
                        var out = DSPSplitComplex(realp: outRealPointer.baseAddress!, imagp: outImagPointer.baseAddress!)
                        fft.inverse(input: split, output: &out)
                        samples.withUnsafeMutableBytes { bytes in
                            vDSP_ztoc(&out, 1, bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                        }
                    }
                }
            }
        }
        // Forward (twice the textbook values) then inverse (size × the input) scale by 2 × size.
        return vDSP.multiply(1 / Float(2 * size), samples)
    }

    // MARK: Masks

    /// Spleeter's ratio mask from the two networks' own masks: each instrument's
    /// estimate squared, over both squared. The magnitudes cancel out, so only
    /// the networks' masks are needed (0.5 where both hear nothing).
    public static func ratioMask(vocals: [Float], accompaniment: [Float]) -> [Float] {
        precondition(vocals.count == accompaniment.count)
        let v = vDSP.square(vocals)
        let a = vDSP.square(accompaniment)
        let tiny: Float = 1e-8
        let numerator = vDSP.add(tiny, v)
        let denominator = vDSP.add(2 * tiny, vDSP.add(v, a))
        return vDSP.divide(numerator, denominator)
    }
}
