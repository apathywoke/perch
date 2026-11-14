import AppKit
import OSLog
import PerchCore

/// A plain-text report for bug reports. It is built only when the user asks,
/// goes to the clipboard and is never sent anywhere. It contains no track names.
enum Diagnostics {
    static func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report(), forType: .string)
    }

    static func report() -> String {
        var lines = ["# Perch diagnostics", "Generated: \(ISO8601DateFormatter().string(from: Date()))"]
        func section(_ title: String, _ rows: [(String, String)]) {
            lines.append("")
            lines.append("## \(title)")
            lines += rows.map { "\($0.0): \($0.1)" }
        }

        let info = Bundle.main.infoDictionary ?? [:]
        section("App", [
            ("Version", info["CFBundleShortVersionString"] as? String ?? "dev"),
            ("Build", info["PerchCommit"] as? String ?? "unknown"),
            ("Location", Bundle.main.bundlePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
            ("Language", Bundle.main.preferredLocalizations.first ?? "?"),
        ])
        section("System", [
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Model", systemValue("hw.model")),
            ("Architecture", architecture),
            ("Reduce motion", yesNo(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)),
            ("VoiceOver", yesNo(NSWorkspace.shared.isVoiceOverEnabled)),
        ])
        section("Displays", NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            let areas = "\(Int(screen.auxiliaryTopLeftArea?.width ?? 0))/\(Int(screen.auxiliaryTopRightArea?.width ?? 0))"
            return ("Display \(index + 1)",
                    "\(Int(frame.width))×\(Int(frame.height)) @\(screen.backingScaleFactor)x, "
                    + "safe area top \(Int(screen.safeAreaInsets.top)), menu bar areas \(areas)")
        })
        section("Island", NotchController.shared.diagnosticRows())
        section("Media", MediaService.shared.diagnosticRows())
        section("Volume and brightness", SystemHUD.shared.diagnosticRows())
        section("Shortcuts", HotkeyCenter.shared.diagnosticRows())
        section("Updates", Updater.shared.diagnosticRows())
        section("Lyrics", LyricsService.shared.diagnosticRows())
        section("Settings", settingsRows())
        section("Recent log (30 min)", recentLog())
        return lines.joined(separator: "\n")
    }

    private static func settingsRows() -> [(String, String)] {
        let defaults = UserDefaults.standard
        var rows = Pref.defaults.keys.sorted().map { key in
            (key, defaults.object(forKey: key).map { "\($0)" } ?? "—")
        }
        rows.append(("ignoredSources", "\(Pref.strings(Pref.ignoredSources).count) apps"))
        rows.append(("onboardingDone", yesNo(Pref.bool(Pref.onboardingDone))))
        return rows
    }

    /// Perch's own log lines. Track names are never logged in the first place.
    private static func recentLog() -> [(String, String)] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [("Log", "unavailable")] }
        let start = store.position(date: Date().addingTimeInterval(-30 * 60))
        let predicate = NSPredicate(format: "subsystem == %@", "dev.perch.Perch")
        guard let entries = try? store.getEntries(at: start, matching: predicate) else { return [("Log", "unavailable")] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let rows = entries.compactMap { $0 as? OSLogEntryLog }.suffix(80).map { entry in
            ("\(formatter.string(from: entry.date)) \(entry.category)", entry.composedMessage)
        }
        return rows.isEmpty ? [("Log", "empty")] : Array(rows)
    }

    private static func systemValue(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
