import AppKit
import os
import PerchCore
import Security

/// Updates from the project's GitHub releases.
///
/// Off unless the user turns it on (or presses "Check now"). Through Network,
/// it makes one request to github.com for the latest release, and downloads
/// the new version when the user asks to install it. Nothing about the user is sent.
///
/// A downloaded build is installed only if its code signature satisfies the
/// designated requirement of the running copy, i.e. it was signed with the
/// same certificate. A copy signed ad hoc names one exact build, so it can
/// only be updated by hand.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "updates")

    static let repository = "apathywoke/perch"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    struct Release: Equatable {
        let version: AppVersion
        let notes: String
        let page: URL
        let archive: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var wasEnabled = false

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Whether a downloaded build can be checked against this copy's signature.
    lazy var canInstallInPlace: Bool = {
        guard let requirement = Self.ownRequirement() else { return false }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        return !((text as String?) ?? "cdhash").contains("cdhash")
    }()

    // MARK: Scheduling

    func start() {
        let stamp = UserDefaults.standard.double(forKey: Pref.lastUpdateCheck)
        lastCheck = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        wasEnabled = Pref.bool(Pref.updateChecks)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.preferencesChanged() }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Not right at launch: give the rest of Perch a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
    }

    private func preferencesChanged() {
        let enabled = Pref.bool(Pref.updateChecks)
        guard enabled != wasEnabled else { return }
        wasEnabled = enabled
        Self.log.notice("Automatic update checks \(enabled ? "on" : "off", privacy: .public)")
        if enabled { check() }
    }

    private func checkIfDue() {
        guard Pref.bool(Pref.updateChecks) else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        check()
    }

    // MARK: Checking

    func check() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        let current = currentVersion
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Self.fetchLatest() }
            DispatchQueue.main.async {
                let now = Date()
                self.lastCheck = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
                switch result {
                case .success(let release) where release.version > current:
                    Self.log.notice("Update available: \(release.version.description, privacy: .public)")
                    self.state = .available(release)
                case .success:
                    self.state = .upToDate
                case .failure(let error):
                    Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func fetchLatest() throws -> Release {
        let response = try Network.get(URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                       headers: ["Accept": "application/vnd.github+json"])
        guard response.status == 200 else {
            throw response.status == 404 ? UpdateError.noRelease : UpdateError.toolFailed("HTTP \(response.status)")
        }
        let data = response.data
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = AppVersion(tag) else {
            throw UpdateError.unreadableRelease
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let assets = json["assets"] as? [[String: Any]] ?? []
        let archive = assets.first {
            guard let name = $0["name"] as? String else { return false }
            return name.hasPrefix("Perch") && name.hasSuffix(".zip")
        }
        let archiveURL = (archive?["browser_download_url"] as? String).flatMap(URL.init(string:))
        // Only ever download from GitHub.
        let trusted = archiveURL.flatMap { $0.scheme == "https" && ($0.host?.hasSuffix("github.com") ?? false) ? $0 : nil }
        return Release(version: version, notes: json["body"] as? String ?? "", page: page, archive: trusted)
    }

    // MARK: Installing

    func install() {
        guard case .available(let release) = state else { return }
        guard canInstallInPlace, let archive = release.archive else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading(release)
        let destination = URL(fileURLWithPath: Bundle.main.bundlePath)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("perch-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }

                let zip = folder.appendingPathComponent("Perch.zip")
                try Network.download(archive, to: zip, maxBytes: 200_000_000)
                let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                let app = unpacked.appendingPathComponent("Perch.app", isDirectory: true)
                try Self.verify(app, newerThan: self.currentVersion)

                DispatchQueue.main.sync { self.state = .installing }
                Self.log.notice("Installing \(release.version.description, privacy: .public)")
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: app)
                DispatchQueue.main.async { AppDelegate.shared?.relaunch() }
            } catch {
                Self.log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// The new build must be Perch, newer, intact and signed like this copy.
    private static func verify(_ app: URL, newerThan current: AppVersion) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.notPerch
        }
        guard let version = AppVersion(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
              version > current else {
            throw UpdateError.notNewer
        }
        guard let requirement = ownRequirement() else { throw UpdateError.untrusted }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.untrusted
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
                                         | UInt32(kSecCSCheckNestedCode))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.untrusted
        }
    }

    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: Processes

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
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
            throw UpdateError.toolFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    // MARK: Diagnostics

    func diagnosticRows() -> [(String, String)] {
        let status = switch state {
        case .idle: "idle"
        case .checking: "checking"
        case .upToDate: "up to date"
        case .available(let release): "update \(release.version) available"
        case .downloading: "downloading"
        case .installing: "installing"
        case .failed: "last check failed"
        }
        return [
            ("Automatic checks", Pref.bool(Pref.updateChecks) ? "on" : "off"),
            ("Last check", lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? "never"),
            ("Status", status),
            ("Signed for updates in place", canInstallInPlace ? "yes" : "no (ad hoc)"),
        ]
    }
}

enum UpdateError: LocalizedError {
    case unreadableRelease, noRelease, notPerch, notNewer, untrusted
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableRelease: NSLocalizedString("GitHub answered, but the release could not be read.", comment: "")
        case .noRelease: NSLocalizedString("No releases have been published yet.", comment: "")
        case .notPerch: NSLocalizedString("The download is not Perch.", comment: "")
        case .notNewer: NSLocalizedString("The download is not newer than this version.", comment: "")
        case .untrusted: NSLocalizedString("The download is not signed like this copy of Perch, so it was not installed.", comment: "")
        case .toolFailed(let message):
            message.isEmpty ? NSLocalizedString("The connection to GitHub failed.", comment: "") : message
        }
    }
}
