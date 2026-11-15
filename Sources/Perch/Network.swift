import Foundation

/// The only place where Perch reaches the network. Requests go through the
/// system `curl`, over HTTPS only, to the hosts listed here, and only for the
/// features the user turned on: update checks, lyrics and the voice separation model.
/// Scripts/check.sh fails if network code appears anywhere else.
enum Network {
    static let allowedHosts: Set<String> = ["api.github.com", "github.com", "lrclib.net"]

    struct Response {
        let status: Int
        let data: Data
    }

    /// GET a URL; any HTTP status comes back, only connection failures throw.
    static func get(_ url: URL, headers: [String: String] = [:]) throws -> Response {
        try check(url)
        let marker = "\n#perch-status:"
        let arguments = baseArguments()
            + headers.sorted { $0.key < $1.key }.flatMap { ["--header", "\($0.key): \($0.value)"] }
            + ["--write-out", "\(marker)%{http_code}", url.absoluteString]
        let output = try run(arguments)
        guard let range = output.range(of: Data(marker.utf8), options: .backwards),
              let status = Int(String(decoding: output[range.upperBound...], as: UTF8.self)) else {
            throw NetworkError.failed("")
        }
        return Response(status: status, data: output[..<range.lowerBound])
    }

    /// Download to a file; fails on any HTTP error.
    static func download(_ url: URL, to file: URL, maxBytes: Int, maxSeconds: Int = 60) throws {
        try check(url)
        try run(baseArguments(maxSeconds: maxSeconds)
                + ["--fail", "--max-filesize", String(maxBytes), "--output", file.path, url.absoluteString])
    }

    private static func check(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host, allowedHosts.contains(host) else {
            throw NetworkError.hostNotAllowed
        }
    }

    /// --disable must come first: it stops curl from reading a user's ~/.curlrc.
    private static func baseArguments(maxSeconds: Int = 60) -> [String] {
        ["--disable", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
         "--max-time", String(maxSeconds), "--user-agent", userAgent]
    }

    /// LRCLIB asks clients to name themselves; this names the app, nothing about the user.
    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Perch/\(version) (+https://github.com/apathywoke/perch)"
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.environment = [:]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NetworkError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}

enum NetworkError: LocalizedError {
    case hostNotAllowed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .hostNotAllowed: "Perch only connects to GitHub and LRCLIB."
        case .failed(let message):
            message.isEmpty ? NSLocalizedString("The connection failed.", comment: "") : message
        }
    }
}
