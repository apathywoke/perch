import AppKit
import Combine
import os
import PerchCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private(set) static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // One island is enough. After "Restart now" the old copy is still quitting,
        // so give it a moment instead of giving up.
        if let id = Bundle.main.bundleIdentifier {
            let others = { NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current } }
            if CommandLine.arguments.contains("--relaunched") {
                let deadline = Date().addingTimeInterval(5)
                while !others().isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            }
            if !others().isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        Pref.register()
        MediaService.shared.start()
        NotchController.shared.start()
        HotkeyCenter.shared.registerAll()
        updateStatusItem()
        SystemHUD.shared.sync()
        if Pref.bool(Pref.onboardingDone) {
            SystemHUD.shared.askOnFirstLaunch()
        } else {
            showOnboarding() // explains the Accessibility request before macOS shows it
        }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                SystemHUD.shared.sync()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaService.shared.stop()
    }

    /// Opening the app again (Finder, Spotlight) is the way back to Settings
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Settings window

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.title = NSLocalizedString("Perch Settings", comment: "")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Welcome window

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in self?.onboardingWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.title = NSLocalizedString("Welcome to Perch", comment: "")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        Logger(subsystem: "dev.perch.Perch", category: "app").notice("Welcome window shown")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        Pref.set(true, Pref.onboardingDone)
        // The permission was explained there; no surprise prompt on a later launch.
        Pref.set(true, Pref.hudAskedForAccess)
        Logger(subsystem: "dev.perch.Perch", category: "app").notice("Welcome window closed")
        DispatchQueue.main.async { [weak self] in self?.onboardingWindow = nil }
    }

    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath, "--args", "--relaunched"]
        MediaService.shared.stop()
        try? process.run()
        // Quit without going through the single-instance check of the new copy.
        exit(0)
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        let wanted = Pref.bool(Pref.showMenuBarIcon)
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Perch")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !wanted, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let media = MediaService.shared
        if let track = media.track {
            let title = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
            let item = NSMenuItem(title: title.count > 60 ? String(title.prefix(59)) + "…" : title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            add(menu, track.isPlaying ? "Pause" : "Play", #selector(playPause))
            add(menu, "Next Track", #selector(nextTrack))
            add(menu, "Previous Track", #selector(previousTrack))
        } else {
            let item = NSMenuItem(title: NSLocalizedString("Nothing is playing", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Quit Perch", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func playPause() { MediaService.shared.togglePlayPause() }
    @objc private func nextTrack() { MediaService.shared.next() }
    @objc private func previousTrack() { MediaService.shared.previous() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
