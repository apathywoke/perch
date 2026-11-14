import PerchCore
import ServiceManagement
import SwiftUI

// MARK: - Window

enum SettingsPane: String, CaseIterable, Identifiable {
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

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "Startup, menu bar and where the island appears."
        case .behavior: "How the island opens, closes and reacts to you."
        case .appearance: "Size, motion and the look of the player."
        case .indicators: "Volume and brightness in the island instead of the system indicators."
        case .sources: "Which apps the island follows."
        case .shortcuts: "Control the music from any app."
        case .about: "A music player for the MacBook notch."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .behavior: "cursorarrow.motionlines"
        case .appearance: "paintbrush.pointed.fill"
        case .indicators: "speaker.wave.2.fill"
        case .sources: "music.note"
        case .shortcuts: "command"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .behavior: .blue
        case .appearance: .pink
        case .indicators: .orange
        case .sources: .red
        case .shortcuts: .indigo
        case .about: .teal
        }
    }
}

struct SettingsView: View {
    @AppStorage(Pref.settingsPane) private var storedPane = SettingsPane.general.rawValue

    private var selection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: storedPane) ?? .general },
                set: { storedPane = ($0 ?? .general).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section { row(.general) }
                Section("Island") {
                    row(.behavior)
                    row(.appearance)
                }
                Section("Music") {
                    row(.sources)
                    row(.shortcuts)
                }
                Section("System") { row(.indicators) }
                Section { row(.about) }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 236)
            .navigationSplitViewColumnWidth(min: 236, ideal: 240, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection.wrappedValue ?? .general {
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
            .toggleStyle(.switch)
        }
        .frame(width: 840, height: 620)
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            IconTile(symbol: pane.symbol, color: pane.color, size: 22)
        }
        .tag(pane)
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
            } header: {
                PaneHeader(pane: .general)
            } footer: {
                if !showMenuBarIcon {
                    Text("Without the icon, open Settings by right-clicking the island or by launching Perch again.")
                }
            }
            Section {
                Picker("Show the island on", selection: $display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show on displays without a notch", isOn: $showOnNonNotch)
                Toggle("Hide in full-screen apps", isOn: $hideInFullscreen)
            } header: {
                Text("Display")
            } footer: {
                Text("On such displays the island appears as a tab at the top edge while music is playing.")
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
                    LabeledContent {
                        Button("Restart now") { AppDelegate.shared?.relaunch() }
                    } label: {
                        Text("The language changes after Perch restarts.").foregroundStyle(.secondary)
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
            Section {
                TilePicker(selection: $openTrigger, options: [
                    TileOption(value: .hover, title: "On hover", symbol: "cursorarrow.rays"),
                    TileOption(value: .click, title: "On click", symbol: "cursorarrow.click.2"),
                ])
                if openTrigger == .hover {
                    SliderRow(title: "Delay before opening", value: $hoverDelay, range: 0...1, step: 0.02, text: seconds)
                    Picker("Click on the collapsed island", selection: $clickAction) {
                        ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                SliderRow(title: "Delay before closing", value: $closeDelay, range: 0.05...2, step: 0.05, text: seconds)
                Toggle("Haptic feedback on the trackpad", isOn: $haptics)
            } header: {
                VStack(alignment: .leading, spacing: 14) {
                    PaneHeader(pane: .behavior)
                    Text("Open the island")
                }
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
    @State private var previewMode = IslandPreview.Mode.open

    var body: some View {
        Form {
            Section {
                IslandPreview(mode: $previewMode)
            } header: {
                PaneHeader(pane: .appearance)
            } footer: {
                HStack {
                    Text("Changes show up here straight away.")
                    Spacer()
                    Button("Preview the expanded island") { NotchController.shared.preview() }
                        .controlSize(.small)
                }
            }
            Section("Motion") {
                TilePicker(selection: $animation, options: [
                    TileOption(value: .snappy, title: "Snappy", symbol: "hare.fill"),
                    TileOption(value: .smooth, title: "Smooth", symbol: "wind"),
                    TileOption(value: .relaxed, title: "Relaxed", symbol: "tortoise.fill"),
                ])
                .onChange(of: animation) { _, _ in replayPreview() }
            }
            Section("Expanded player") {
                SliderRow(title: "Size", value: $scale, range: 0.85...1.35, step: 0.05) {
                    String(format: "%.0f%%", $0 * 100)
                }
                Toggle("Glow in the colour of the artwork", isOn: $glow)
                Toggle("Shadow under the island", isOn: $shadow)
                Toggle("Show the album name", isOn: $showAlbum)
                Picker("Right-hand time label", selection: $timeStyle) {
                    ForEach(TimeStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Swap the artwork and the visualizer", isOn: $swapSides)
            } header: {
                Text("Collapsed island")
            }
            Section {
                Toggle("Show the visualizer", isOn: $visualizer)
                if visualizer {
                    LabeledContent("Colour") { SwatchPicker(selection: $visualizerColor) }
                }
            } header: {
                Text("Visualizer")
            } footer: {
                Text("The visualizer is decorative. Perch never records or analyses audio.")
            }
        }
    }

    /// Plays the open animation again so the chosen style can be felt.
    private func replayPreview() {
        let mode = previewMode
        previewMode = mode == .collapsed ? .open : .collapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { previewMode = mode == .collapsed ? .open : mode }
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
                        Label {
                            Text("Accessibility access is granted.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Perch needs Accessibility access to take over the volume and brightness keys.")
                                Text("If Perch is already in the list and switched on, remove it with the “−” button and add it again: macOS keeps an entry for an older build.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        LabeledContent("") {
                            Button("Open System Settings") { hud.openSystemSettings() }
                        }
                    }
                }
            } header: {
                PaneHeader(pane: .indicators)
            } footer: {
                Text("This replaces the system indicators. Perch receives only the media keys, never ordinary keystrokes. Hold ⌥⇧ for finer steps.")
            }
            if enabled {
                Section {
                    IslandPreview(mode: .constant(.indicator), showsModes: false)
                    TilePicker(selection: $style, options: HUDStyle.allCases.map { option in
                        TileOption(value: option, title: option.title) { HUDStyleIllustration(style: option) }
                    })
                } header: {
                    Text("Position")
                }
                Section("Show for") {
                    Toggle("Volume", isOn: $volume)
                    Toggle("Brightness", isOn: $brightness)
                }
                Section("Appearance") {
                    LabeledContent("Bar colour") { SwatchPicker(selection: $color) }
                    Toggle("Show the value as a number", isOn: $percent)
                    SliderRow(title: "Hide after", value: $duration, range: 0.6...4, step: 0.2, text: seconds)
                    LabeledContent("") {
                        Button("Preview") {
                            NotchController.shared.showHUD(HUDState(kind: .volume, value: 0.6))
                        }
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
                                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                            } else {
                                IconTile(symbol: "app.dashed", color: .gray, size: 26)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: MediaService.name(for: id))
                                Text(verbatim: id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 14) {
                    PaneHeader(pane: .sources)
                    Text("Apps shown in the island")
                }
            } footer: {
                HStack(alignment: .top) {
                    Text("Perch shows whatever macOS reports as “Now Playing”. Turn off an app, a browser for example, to ignore what it plays.")
                    if !media.knownSources.isEmpty {
                        Spacer()
                        Button("Clear the list") { media.clearSources() }
                            .controlSize(.small)
                    }
                }
            }
            Section {
                LabeledContent("System “Now Playing”") {
                    if media.helperFailed {
                        HStack(spacing: 8) {
                            StatusBadge(text: "Unavailable", color: .orange)
                            Button("Try again") { media.retryHelper() }
                        }
                    } else {
                        StatusBadge(text: "Working", color: .green)
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
                    LabeledContent {
                        HotkeyRecorder(action: action)
                    } label: {
                        Label {
                            Text(action.title)
                        } icon: {
                            Image(systemName: action.symbol).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                PaneHeader(pane: .shortcuts)
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

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info["PerchCommit"] as? String).map { " (\($0))" } ?? ""
        return String(format: NSLocalizedString("Version %@", comment: ""), version + build)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                        .accessibilityHidden(true)
                    Text(verbatim: "Perch")
                        .font(.system(size: 28, weight: .bold))
                    Text(verbatim: versionLine)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("A music player for the MacBook notch.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section("Privacy") {
                PrivacyRow(symbol: "eye.slash.fill", color: .blue, text: "No telemetry, analytics or crash reporting.")
                PrivacyRow(symbol: "wifi.slash", color: .green, text: "No network connections of any kind.")
                PrivacyRow(symbol: "lock.fill", color: .orange, text: "No Screen Recording or microphone access.")
                PrivacyRow(symbol: "hand.raised.fill", color: .indigo,
                           text: "Accessibility is requested only for the optional volume and brightness indicators.")
                PrivacyRow(symbol: "music.note", color: .red,
                           text: "Control of Spotify or Music is requested only when the backup source is in use.")
                PrivacyRow(symbol: "chevron.left.forwardslash.chevron.right", color: .gray,
                           text: "Open source under the GNU GPL v3 licence.")
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                        Button("Copy diagnostics") {
                            Diagnostics.copyToClipboard()
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                        }
                    }
                } label: {
                    Text("Diagnostics")
                }
            } footer: {
                Text("A report about Perch and this Mac for bug reports. It goes only to the clipboard and contains no track names.")
            }
            Section {
                HStack {
                    Button("Show the welcome screen") { AppDelegate.shared?.showOnboarding() }
                    Spacer()
                    Button("Reset all settings…") { confirmReset = true }
                    Button("Quit Perch") { NSApp.terminate(nil) }
                }
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

// MARK: - Building blocks

/// A white symbol on a coloured rounded square, like System Settings.
private struct IconTile: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Big icon, title and one line about the pane, at the top of each pane.
private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: pane.symbol, color: pane.color, size: 46)
                .shadow(color: pane.color.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct StatusBadge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let color: Color
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            IconTile(symbol: symbol, color: color, size: 22)
        }
    }
}

private struct TileOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: LocalizedStringKey
    let artwork: AnyView
    var id: Value { value }

    init(value: Value, title: LocalizedStringKey, symbol: String) {
        self.value = value
        self.title = title
        self.artwork = AnyView(
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(height: 26)
        )
    }

    init<Artwork: View>(value: Value, title: LocalizedStringKey, @ViewBuilder artwork: () -> Artwork) {
        self.value = value
        self.title = title
        self.artwork = AnyView(artwork())
    }
}

/// A choice shown as tiles with a picture each, instead of a pop-up menu.
private struct TilePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [TileOption<Value>]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    VStack(spacing: 8) {
                        option.artwork
                        Text(option.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                          lineWidth: selected ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Colour choice as round swatches.
private struct SwatchPicker: View {
    @Binding var selection: VisualizerColor

    var body: some View {
        HStack(spacing: 10) {
            Text(selection.title).foregroundStyle(.secondary)
            ForEach(VisualizerColor.allCases) { option in
                Button {
                    selection = option
                } label: {
                    swatch(option)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selection == option ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text(option.title))
                .accessibilityLabel(Text(option.title))
                .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    @ViewBuilder private func swatch(_ option: VisualizerColor) -> some View {
        switch option {
        case .artwork:
            Circle().fill(AngularGradient(colors: [.pink, .orange, .yellow, .green, .teal, .blue, .purple, .pink],
                                          center: .center))
        case .white:
            Circle().fill(.white)
        case .accent:
            Circle().fill(Color.accentColor)
        }
    }
}

/// A tiny drawing of where the volume indicator appears.
private struct HUDStyleIllustration: View {
    let style: HUDStyle

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.indigo.opacity(0.7), Color.purple.opacity(0.45)],
                                     startPoint: .top, endPoint: .bottom))
            switch style {
            case .beside:
                HStack(spacing: 0) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7, weight: .bold))
                        .frame(width: 26)
                    Spacer(minLength: 30)
                    Capsule().fill(.white).frame(width: 16, height: 3).frame(width: 26)
                }
                .foregroundStyle(.white)
                .frame(width: 104, height: 14)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5).fill(.black))
            case .below:
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 7, weight: .bold))
                    Capsule().fill(.white).frame(width: 30, height: 3)
                }
                .foregroundStyle(.white)
                .padding(.top, 13)
                .frame(width: 74, height: 26, alignment: .top)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black))
            }
        }
        .frame(width: 128, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A live island on a little stretch of desktop. It uses the real views and
/// settings, so every change shows up here at once, animations included.
private struct IslandPreview: View {
    enum Mode: String, CaseIterable, Identifiable {
        case collapsed, open, card, indicator
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .collapsed: "Collapsed"
            case .open: "Open"
            case .card: "Track card"
            case .indicator: "Indicator"
            }
        }
    }

    @Binding var mode: Mode
    var showsModes = true
    @StateObject private var model = NotchModel()
    @StateObject private var sample = MediaService.preview()
    @ObservedObject private var media = MediaService.shared
    @AppStorage(Pref.scale) private var scale = 1.0
    @AppStorage(Pref.hudStyle) private var hudStyle = HUDStyle.beside

    private static let zoom: CGFloat = 0.8

    /// Tall enough for the island in its current state, so no empty desktop is left.
    private var height: CGFloat {
        let island = NotchLayout.size(phase: model.phase, notch: model.notchSize, hasNotch: model.hasNotch,
                                      active: true, scale: scale, hud: model.hud == nil ? nil : hudStyle)
        return island.height * Self.zoom + 34
    }

    var body: some View {
        VStack(spacing: 12) {
            if showsModes {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.2, blue: 0.55), Color(red: 0.46, green: 0.23, blue: 0.6),
                                        Color(red: 0.9, green: 0.5, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(height: model.notchSize.height * 0.8)
                    .frame(maxHeight: .infinity, alignment: .top)
                IslandView(model: model, media: media.track == nil ? sample : media)
                    .scaleEffect(Self.zoom, anchor: .top)
                    .allowsHitTesting(false)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Island preview"))
        }
        .padding(.vertical, 6)
        .onAppear { configure(animated: false) }
        .onChange(of: mode) { _, _ in configure(animated: true) }
    }

    private func configure(animated: Bool) {
        let real = NotchController.shared.model
        model.notchSize = real.notchSize
        model.hasNotch = real.hasNotch
        model.visible = true
        model.active = true
        let apply = {
            switch mode {
            case .collapsed:
                model.phase = .collapsed
                model.hud = nil
            case .open:
                model.phase = .expanded
                model.hud = nil
            case .card:
                model.phase = .peek
                model.hud = nil
            case .indicator:
                model.phase = .collapsed
                model.hud = HUDState(kind: .volume, value: 0.6)
            }
        }
        if animated {
            withAnimation(mode == .collapsed ? Motion.shrink : Motion.grow, apply)
        } else {
            apply()
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
                    .frame(width: 200)
                    .accessibilityLabel(Text(title))
                Text(verbatim: text(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}
