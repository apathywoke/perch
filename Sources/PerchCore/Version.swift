import Foundation

/// A release version such as "0.1", "0.1.0" or the tag "v1.2.3".
/// Missing parts count as zero, so 0.1 and 0.1.0 are the same version.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        // "1.2.3-beta.1" or "1.2.3+build": only the numbers before the suffix count.
        if let end = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = body[..<end] }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let number = Int(piece), number >= 0 else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let count = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: count - a.parts.count),
                b.parts + Array(repeating: 0, count: count - b.parts.count))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x == y
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x.lexicographicallyPrecedes(y)
    }
}
