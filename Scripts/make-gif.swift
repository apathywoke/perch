// Turns the frames from `Perch --snapshot-demo` into an animated GIF for the README.
//
//   swiftc -O Scripts/make-gif.swift -o make-gif
//   ./make-gif <frames folder> <output.gif> [scale] [dither]
//
// The folder holds frame-0000.png… and times.txt (seconds since the start, one
// line per frame). ImageIO writes every GIF frame whole; here a frame keeps only
// the rectangle that changed, with unchanged pixels transparent, which makes the
// file many times smaller. One palette for all frames, so colours don't flicker.

import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: make-gif <frames folder> <output.gif> [scale]")
    exit(1)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2])
let scale = arguments.count > 3 ? Double(arguments[3]) ?? 1 : 1
let dither = arguments.count > 4 ? Double(arguments[4]) ?? 0 : 0

let frameURLs = (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
    .filter { $0.lastPathComponent.hasPrefix("frame-") && $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let times = try String(contentsOf: folder.appendingPathComponent("times.txt"), encoding: .utf8)
    .split(separator: "\n").compactMap { Double($0) }
guard !frameURLs.isEmpty, times.count == frameURLs.count else {
    print("frames and times.txt don't match")
    exit(1)
}

// MARK: Loading

struct Pixels {
    let width: Int, height: Int
    var rgba: [UInt8]
}

func load(_ url: URL) -> Pixels {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("can't read \(url.path)")
    }
    let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Pixels(width: width, height: height, rgba: rgba)
}

// MARK: Palette (median cut on a 6-bit-per-channel histogram)

// Colours are quantized on a square-root scale: the island is mostly near-black,
// where steps between palette colours show most, so darks get more of them.
let encode = (0 ... 255).map { UInt8((255 * (Double($0) / 255).squareRoot()).rounded()) }
let decode = (0 ... 255).map { UInt8((255 * pow(Double($0) / 255, 2)).rounded()) }

func key(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
    Int(encode[Int(r)] >> 2) << 12 | Int(encode[Int(g)] >> 2) << 6 | Int(encode[Int(b)] >> 2)
}

var histogram = [Int](repeating: 0, count: 1 << 18)
for url in frameURLs {
    let frame = load(url)
    var i = 0
    while i < frame.rgba.count {
        histogram[key(frame.rgba[i], frame.rgba[i + 1], frame.rgba[i + 2])] += 1
        i += 4 * 2
    }
}

struct Box {
    var bins: [Int]
    var count: Int
    var error: Double
    var mean: (Double, Double, Double)
}

func channel(_ bin: Int, _ c: Int) -> Double { Double((bin >> (12 - 6 * c)) & 63) * 4 + 2 }

func makeBox(_ bins: [Int]) -> Box {
    var count = 0, sum = (0.0, 0.0, 0.0)
    for bin in bins {
        let n = Double(histogram[bin])
        count += histogram[bin]
        sum.0 += channel(bin, 0) * n; sum.1 += channel(bin, 1) * n; sum.2 += channel(bin, 2) * n
    }
    let total = Double(max(count, 1))
    let mean = (sum.0 / total, sum.1 / total, sum.2 / total)
    var error = 0.0
    for bin in bins {
        let d = (channel(bin, 0) - mean.0, channel(bin, 1) - mean.1, channel(bin, 2) - mean.2)
        error += Double(histogram[bin]) * (d.0 * d.0 + d.1 * d.1 + d.2 * d.2)
    }
    return Box(bins: bins, count: count, error: error, mean: mean)
}

var boxes = [makeBox((0 ..< histogram.count).filter { histogram[$0] > 0 })]
// Index 255 is kept for "unchanged" (transparent).
while boxes.count < 255 {
    guard let worst = boxes.indices.filter({ boxes[$0].bins.count > 1 }).max(by: { boxes[$0].error < boxes[$1].error })
    else { break }
    let box = boxes.remove(at: worst)
    // Split along the channel that varies most, at the median pixel.
    let spread = (0 ..< 3).map { c -> Double in
        let values = box.bins.map { channel($0, c) }
        return values.max()! - values.min()!
    }
    let axis = spread.firstIndex(of: spread.max()!)!
    let sorted = box.bins.sorted { channel($0, axis) < channel($1, axis) }
    var running = 0, cut = 1
    for (index, bin) in sorted.enumerated() {
        running += histogram[bin]
        if running * 2 >= box.count { cut = min(max(index + 1, 1), sorted.count - 1); break }
    }
    boxes.append(makeBox(Array(sorted[..<cut])))
    boxes.append(makeBox(Array(sorted[cut...])))
}
// Palette entries on the square-root scale, and as written to the file.
let scaled = boxes.map { (Int($0.mean.0.rounded()), Int($0.mean.1.rounded()), Int($0.mean.2.rounded())) }
let palette = scaled.map { (decode[min($0.0, 255)], decode[min($0.1, 255)], decode[min($0.2, 255)]) }
let transparent = 255

var lookup = [Int16](repeating: -1, count: 1 << 18)
func index(forKey k: Int) -> UInt8 {
    if lookup[k] >= 0 { return UInt8(lookup[k]) }
    let r = (k >> 12) * 4 + 2, g = (k >> 6 & 63) * 4 + 2, b = (k & 63) * 4 + 2
    var best = 0, bestDistance = Int.max
    for (i, color) in scaled.enumerated() {
        let dr = color.0 - r, dg = color.1 - g, db = color.2 - b
        let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
        if distance < bestDistance { bestDistance = distance; best = i }
    }
    lookup[k] = Int16(best)
    return UInt8(best)
}

// Ordered dithering softens the steps in faint glows and shadows. The pattern
// stays put from frame to frame, so unchanged pixels stay unchanged.
let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 - 0.5 }
func index(_ r: UInt8, _ g: UInt8, _ b: UInt8, x: Int, y: Int) -> UInt8 {
    let offset = Int((bayer[(y & 3) * 4 + (x & 3)] * dither).rounded())
    func level(_ v: UInt8) -> Int { min(63, max(0, (Int(encode[Int(v)]) + offset) >> 2)) }
    return index(forKey: level(r) << 12 | level(g) << 6 | level(b))
}

// MARK: LZW

func lzw(_ indices: [UInt8]) -> [UInt8] {
    let minimum = 8, clear = 1 << minimum, end = clear + 1
    var bytes: [UInt8] = [], bitBuffer = 0, bitCount = 0
    func emit(_ code: Int, _ size: Int) {
        bitBuffer |= code << bitCount
        bitCount += size
        while bitCount >= 8 {
            bytes.append(UInt8(bitBuffer & 0xFF))
            bitBuffer >>= 8
            bitCount -= 8
        }
    }
    var table = [Int16](repeating: -1, count: 4096 * 256)
    var size = minimum + 1, next = end + 1
    emit(clear, size)
    var prefix = Int(indices[0])
    for i in 1 ..< indices.count {
        let k = Int(indices[i])
        let slot = prefix << 8 | k
        let found = table[slot]
        if found >= 0 { prefix = Int(found); continue }
        emit(prefix, size)
        if next == 4096 {
            emit(clear, size)
            for j in table.indices { table[j] = -1 }
            size = minimum + 1
            next = end + 1
        } else {
            if next >= 1 << size { size += 1 }
            table[slot] = Int16(next)
            next += 1
        }
        prefix = k
    }
    emit(prefix, size)
    emit(end, size)
    if bitCount > 0 { bytes.append(UInt8(bitBuffer & 0xFF)) }
    return bytes
}

// MARK: Writing

var gif = Data()
func u16(_ value: Int) { gif.append(UInt8(value & 0xFF)); gif.append(UInt8(value >> 8)) }

let first = load(frameURLs[0])
let width = first.width, height = first.height
gif.append(contentsOf: Array("GIF89a".utf8))
u16(width); u16(height)
gif.append(contentsOf: [0xF7, 0, 0])
for i in 0 ..< 256 {
    let color = i < palette.count ? palette[i] : (0, 0, 0)
    gif.append(contentsOf: [color.0, color.1, color.2])
}
gif.append(contentsOf: [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00])

struct Pending { var x = 0, y = 0, w = 0, h = 0, data: [UInt8] = [], first = false, end = 0.0 }
var shown = [UInt8](repeating: 0, count: width * height)
var pending: Pending?
var written = 0   // centiseconds of animation written so far

func flush(_ frame: Pending) {
    let target = Int((frame.end * 100).rounded())
    let delay = max(2, target - written)
    written += delay
    gif.append(contentsOf: [0x21, 0xF9, 0x04, frame.first ? 0x04 : 0x05])
    u16(delay)
    gif.append(contentsOf: [UInt8(transparent), 0x00, 0x2C])
    u16(frame.x); u16(frame.y); u16(frame.w); u16(frame.h)
    gif.append(contentsOf: [0x00, 0x08])
    let compressed = lzw(frame.data)
    var offset = 0
    while offset < compressed.count {
        let n = min(255, compressed.count - offset)
        gif.append(UInt8(n))
        gif.append(contentsOf: compressed[offset ..< offset + n])
        offset += n
    }
    gif.append(0x00)
}

for (number, url) in frameURLs.enumerated() {
    let frame = number == 0 ? first : load(url)
    var current = [UInt8](repeating: 0, count: width * height)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let p = y * width + x
            current[p] = index(frame.rgba[p * 4], frame.rgba[p * 4 + 1], frame.rgba[p * 4 + 2], x: x, y: y)
        }
    }
    // Shown until the next frame was captured; the last one holds a little longer.
    let end = number + 1 < times.count ? times[number + 1] - times[0] : times[number] - times[0] + 0.6
    var minX = width, minY = height, maxX = -1, maxY = -1
    if number == 0 {
        minX = 0; minY = 0; maxX = width - 1; maxY = height - 1
    } else {
        for y in 0 ..< height {
            let row = y * width
            for x in 0 ..< width where current[row + x] != shown[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
    }
    if maxX < 0 {
        // Nothing changed: the previous frame stays up longer.
        pending?.end = end
        continue
    }
    if let previous = pending { flush(previous) }
    var data = [UInt8]()
    data.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
    for y in minY ... maxY {
        for x in minX ... maxX {
            let p = y * width + x
            data.append(number > 0 && current[p] == shown[p] ? UInt8(transparent) : current[p])
        }
    }
    shown = current
    pending = Pending(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1, data: data, first: number == 0, end: end)
}
if let last = pending { flush(last) }
gif.append(0x3B)
try gif.write(to: output)
print("\(output.lastPathComponent): \(width)×\(height), \(frameURLs.count) frames, \(gif.count / 1024) KB")
