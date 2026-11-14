import PerchCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general, behavior, appearance, indicators, sources, shortcuts, about
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .behavior: "Behavior"
            case .appearance: "Appearance"
            case .indicators: "Volume & Brightness"
            case .sources: "Music Sources"
            case .shortcuts: "Shortcuts"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .behavior: "cursorarrow.motionlines"
            case .appearance: "paintbrush"
            case .indicators: "speaker.wave.2"
            case .sources: "music.note.list"
            case .shortcuts: "keyboard"
            case .about: "info.circle"
            }
        }
    }

    @State private var pane: Pane? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            .padding(.top, 18)

            Divider()

            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .behavior: BehaviorPane()
                case .appearance: AppearancePane()
                case .indicators: IndicatorsPane()
                case .sources: SourcesPane()
                case .shortcuts: ShortcutsPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 520)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(Pref.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Pref.display) private var display = DisplayChoice.auto
    @AppStorage(Pref.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Pref.showOnNonNotch) private var showOnNonNotch = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(verbatim: loginError).font(.footnote).foregroundStyle(.red)
                }
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
                if !showMenuBarIcon {
                    Text("Without the icon, open Settings by right-clicking the island or by launching Perch again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Display") {
                Picker("Show the island on", selection: $display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show on displays without a notch", isOn: $showOnNonNotch)
                Text("On such displays the island appears as a tab at the top edge while music is playing.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Hide in full-screen apps", isOn: $hideInFullscreen)
            }
            Section("Language") {
                Picker("Interface language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, new in
                    AppLanguage.current = new
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("The language changes after Perch restarts.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now") { AppDelegate.shared?.relaunch() }
                    }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Behavior

private struct BehaviorPane: View {
    @AppStorage(Pref.openTrigger) private var openTrigger = OpenTrigger.hover
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.35
    @AppStorage(Pref.closeDelay) private var closeDelay = 0.25
    @AppStorage(Pref.clickAction) private var clickAction = ClickAction.expand
    @AppStorage(Pref.haptics) private var haptics = true
    @AppStorage(Pref.peekOnTrackChange) private var peek = true
    @AppStorage(Pref.peekDuration) private var peekDuration = 3.0
    @AppStorage(Pref.hidePausedAfter) private var hidePausedAfter = 30.0
    @AppStorage(Pref.swipeGestures) private var swipe = true
    @AppStorage(Pref.invertSwipe) private var invertSwipe = false

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open the island", selection: $openTrigger) {
                    ForEach(OpenTrigger.allCases) { Text($0.title).tag($0) }
                }
                if openTrigger == .hover {
                    SliderRow(title: "Delay before opening", value: $hoverDelay, range: 0...1, step: 0.02, text: seconds)
                    Picker("Click on the collapsed island", selection: $clickAction) {
                        ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                SliderRow(title: "Delay before closing", value: $closeDelay, range: 0.05...2, step: 0.05, text: seconds)
                Toggle("Haptic feedback on the trackpad", isOn: $haptics)
            }
            Section("Track changes") {
                Toggle("Briefly show the new track's name", isOn: $peek)
                if peek {
                    SliderRow(title: "Show for", value: $peekDuration, range: 1...8, step: 0.5, text: seconds)
                }
            }
            Section("Pause") {
                Picker("Hide the island when paused", selection: $hidePausedAfter) {
                    Text("Never").tag(0.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 15 seconds").tag(15.0)
                    Text("After 30 seconds").tag(30.0)
                    Text("After 1 minute").tag(60.0)
                    Text("After 5 minutes").tag(300.0)
                }
            }
            Section("Gestures") {
                Toggle("Swipe sideways with two fingers to change track", isOn: $swipe)
                if swipe {
                    Toggle("Reverse swipe direction", isOn: $invertSwipe)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage(Pref.scale) private var scale = 1.0
    @AppStorage(Pref.animation) private var animation = AnimationStyle.smooth
    @AppStorage(Pref.visualizer) private var visualizer = true
    @AppStorage(Pref.visualizerColor) private var visualizerColor = VisualizerColor.artwork
    @AppStorage(Pref.swapSides) private var swapSides = false
    @AppStorage(Pref.artworkGlow) private var glow = true
    @AppStorage(Pref.showAlbum) private var showAlbum = false
    @AppStorage(Pref.timeStyle) private var timeStyle = TimeStyle.remaining
    @AppStorage(Pref.shadow) private var shadow = true

    var body: some View {
        Form {
            Section("Expanded player") {
                SliderRow(title: "Size", value: $scale, range: 0.85...1.35, step: 0.05) {
                    String(format: "%.0f%%", $0 * 100)
                }
                Picker("Animation", selection: $animation) {
                    ForEach(AnimationStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Glow in the colour of the artwork", isOn: $glow)
                Toggle("Shadow under the island", isOn: $shadow)
                Toggle("Show the album name", isOn: $showAlbum)
                Picker("Right-hand time label", selection: $timeStyle) {
                    ForEach(TimeStyle.allCases) { Text($0.title).tag($0) }
                }
                Button("Preview the expanded island") { NotchController.shared.preview() }
            }
            Section("Collapsed island") {
                Toggle("Swap the artwork and the visualizer", isOn: $swapSides)
            }
            Section("Visualizer") {
                Toggle("Show the visualizer", isOn: $visualizer)
                if visualizer {
                    Picker("Colour", selection: $visualizerColor) {
                        ForEach(VisualizerColor.allCases) { Text($0.title).tag($0) }
                    }
                }
                Text("The visualizer is decorative. Perch never records or analyses audio.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Volume & brightness

private struct IndicatorsPane: View {
    @ObservedObject private var hud = SystemHUD.shared
    @AppStorage(Pref.hudEnabled) private var enabled = true
    @AppStorage(Pref.hudVolume) private var volume = true
    @AppStorage(Pref.hudBrightness) private var brightness = true
    @AppStorage(Pref.hudStyle) private var style = HUDStyle.beside
    @AppStorage(Pref.hudPercent) private var percent = true
    @AppStorage(Pref.hudColor) private var color = VisualizerColor.white
    @AppStorage(Pref.hudDuration) private var duration = 1.6

    var body: some View {
        Form {
            Section {
                Toggle("Show volume and brightness in the island", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on, !hud.trusted { hud.requestAccess() }
                    }
                if enabled {
                    if hud.trusted {
                        Label("Accessibility access is granted.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Perch needs Accessibility access to take over the volume and brightness keys.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("If Perch is already in the list and switched on, remove it with the “−” button and add it again: macOS keeps an entry for an older build.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open System Settings") { hud.openSystemSettings() }
                    }
                }
            } footer: {
                Text("This replaces the system indicators. Perch receives only the media keys, never ordinary keystrokes. Hold ⌥⇧ for finer steps.")
            }
            if enabled {
                Section("Show for") {
                    Toggle("Volume", isOn: $volume)
                    Toggle("Brightness", isOn: $brightness)
                }
                Section("Appearance") {
                    Picker("Position", selection: $style) {
                        ForEach(HUDStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Bar colour", selection: $color) {
                        ForEach(VisualizerColor.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show the value as a number", isOn: $percent)
                    SliderRow(title: "Hide after", value: $duration, range: 0.6...4, step: 0.2, text: seconds)
                    Button("Preview") {
                        NotchController.shared.showHUD(HUDState(kind: .volume, value: 0.6))
                    }
                }
            }
        }
    }
}

// MARK: - Sources

private struct SourcesPane: View {
    @ObservedObject private var media = MediaService.shared
    @AppStorage(Pref.fallbackSources) private var fallback = true

    var body: some View {
        Form {
            Section {
                if media.knownSources.isEmpty {
                    Text("Apps appear here once they start playing something.")
                        .foregroundStyle(.secondary)
                }
                ForEach(media.knownSources, id: \.self) { id in
                    Toggle(isOn: Binding(get: { !media.ignoredSources.contains(id) },
                                         set: { media.setSource(id, enabled: $0) })) {
                        HStack(spacing: 10) {
                            if let icon = MediaService.icon(for: id) {
                                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 20)).frame(width: 26, height: 26)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: MediaService.name(for: id))
                                Text(verbatim: id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Apps shown in the island")
            } footer: {
                Text("Perch shows whatever macOS reports as “Now Playing”. Turn off an app, a browser for example, to ignore what it plays.")
            }
            if !media.knownSources.isEmpty {
                Section {
                    Button("Clear the list") { media.clearSources() }
                }
            }
            Section {
                LabeledContent("System “Now Playing”") {
                    if media.helperFailed {
                        HStack(spacing: 8) {
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Try again") { media.retryHelper() }
                        }
                    } else {
                        Label("Working", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Toggle("Follow Spotify and Music directly when needed", isOn: $fallback)
                if case .fallback(let player) = media.source {
                    Text("Backup source in use for \(MediaService.name(for: player.rawValue))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup source")
            } footer: {
                Text("Spotify and Music announce what they play to any app. Perch uses this only when the system “Now Playing” service misses the music. To control them from the island in that case, macOS asks for permission once per app.")
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent { HotkeyRecorder(action: action) } label: { Text(action.title) }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Shortcuts work in any app and need at least ⌘, ⌥ or ⌃. Press Esc to cancel recording.")
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Perch").font(.title2.weight(.semibold))
                        Text(verbatim: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                            .foregroundStyle(.secondary)
                        Text("A music player for the MacBook notch.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Privacy") {
                Label("No telemetry, analytics or crash reporting.", systemImage: "eye.slash")
                Label("No network connections of any kind.", systemImage: "wifi.slash")
                Label("No Screen Recording or microphone access.", systemImage: "lock.shield")
                Label("Accessibility is requested only for the optional volume and brightness indicators.", systemImage: "hand.raised")
                Label("Control of Spotify or Music is requested only when the backup source is in use.", systemImage: "music.note")
                Label("Open source under the GNU GPL v3 licence.", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Section {
                HStack {
                    Button("Copy diagnostics") {
                        Diagnostics.copyToClipboard()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("A report about Perch and this Mac for bug reports. It goes only to the clipboard and contains no track names.")
            }
            Section {
                Button("Show the welcome screen") { AppDelegate.shared?.showOnboarding() }
                Button("Reset all settings…") { confirmReset = true }
                Button("Quit Perch") { NSApp.terminate(nil) }
            }
        }
        .confirmationDialog("Reset all Perch settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Pref.resetAll()
                MediaService.shared.reloadPreferences()
                HotkeyCenter.shared.reload()
            }
        }
    }
}

// MARK: - Helpers

private func seconds(_ value: Double) -> String {
    String(format: NSLocalizedString("%.2f s", comment: "seconds"), value)
}

private struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 190)
                    .accessibilityLabel(Text(title))
                Text(verbatim: text(value))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}
