import AppKit
import Foundation
import os
import PerchCore
import UniformTypeIdentifiers

/// The user's own lyrics files, in ~/Library/Application Support/Perch/Lyrics.
/// They take the place of LRCLIB for their songs. Files can be added from the
/// lyrics panel or dropped into the folder by hand as "Artist - Title.lrc".
enum UserLyricsStore {
    static let log = Logger(subsystem: "dev.perch.Perch", category: "user-lyrics")

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Lyrics", isDirectory: true)
    }

    private static let extensions: Set<String> = ["lrc", "txt"]

    /// The file holding this song's lyrics, if the user gave one.
    static func file(for track: Track) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let exact = UserLyrics.fileName(title: track.title, artist: track.artist)
        if names.contains(exact) { return folder.appendingPathComponent(exact) }
        return names.sorted().first { name in
            let url = URL(fileURLWithPath: name)
            return extensions.contains(url.pathExtension.lowercased())
                && UserLyrics.matches(stem: url.deletingPathExtension().lastPathComponent,
                                      title: track.title, artist: track.artist)
        }.map { folder.appendingPathComponent($0) }
    }

    static func lyrics(for track: Track) -> Lyrics? {
        guard let url = file(for: track),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? .max) <= UserLyrics.maximumSize,
              let data = try? Data(contentsOf: url),
              let text = UserLyrics.decode(data) else { return nil }
        return UserLyrics.parse(text)
    }

    static func count() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.count
    }

    enum AddError: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: NSLocalizedString("The file could not be read as text.", comment: "")
            case .empty: NSLocalizedString("The file has no lyrics in it.", comment: "")
            }
        }
    }

    /// Copies the chosen file in as this song's lyrics, replacing any it had.
    static func add(_ source: URL, for track: Track) throws {
        let data = try Data(contentsOf: source)
        guard let text = UserLyrics.decode(data) else { throw AddError.unreadable }
        guard UserLyrics.parse(text) != nil else { throw AddError.empty }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = file(for: track) { try? FileManager.default.removeItem(at: old) }
        let target = folder.appendingPathComponent(UserLyrics.fileName(title: track.title, artist: track.artist))
        try Data(text.utf8).write(to: target, options: .atomic)
    }

    /// Moves this song's file to the Trash.
    static func remove(for track: Track) {
        guard let url = file(for: track) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            log.error("Could not move lyrics file to the Trash: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func showInFinder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Asks for a lyrics file for this song, then shows it.
    static func choose(for track: Track) {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Lyrics for this song", comment: "")
        panel.message = String(format: NSLocalizedString("Choose a lyrics file for “%@”: LRC with timing, or plain text.", comment: ""),
                               track.title)
        panel.prompt = NSLocalizedString("Use", comment: "")
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc"), .plainText, .text].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try add(url, for: track)
                LyricsService.shared.reload(for: track)
            } catch {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("These lyrics could not be used", comment: "")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
