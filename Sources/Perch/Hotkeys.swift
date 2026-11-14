import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags
    var label: String
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case playPause, next, previous, toggleIsland
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .playPause: "Play / pause"
        case .next: "Next track"
        case .previous: "Previous track"
        case .toggleIsland: "Open or close the island"
        }
    }
}

/// Global shortcuts through the Carbon hot key API. Unlike event taps it needs
/// no Accessibility permission and never sees any other keystrokes.
final class HotkeyCenter: ObservableObject {
    static let shared = HotkeyCenter()

    @Published private(set) var bindings: [String: Hotkey] = [:]
    /// Actions whose shortcut macOS refused (usually taken by the system or another app).
    @Published private(set) var failed: Set<String> = []
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Pref.hotkeys),
           let saved = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            bindings = saved
        }
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? { bindings[action.rawValue] }

    func diagnosticRows() -> [(String, String)] {
        [
            ("Assigned", "\(bindings.count)"),
            ("Refused by macOS", failed.isEmpty ? "—" : failed.sorted().joined(separator: ", ")),
        ]
    }

    func set(_ hotkey: Hotkey?, for action: HotkeyAction) {
        if let hotkey {
            // A combination can only belong to one action.
            for (key, value) in bindings where value.keyCode == hotkey.keyCode && value.modifiers == hotkey.modifiers {
                bindings[key] = nil
            }
        }
        bindings[action.rawValue] = hotkey
        if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: Pref.hotkeys) }
        registerAll()
    }

    func reload() {
        bindings = [:]
        registerAll()
    }

    func registerAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        installHandlerIfNeeded()
        var failed: Set<String> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let hotkey = bindings[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5052_4348) /* 'PRCH' */, id: UInt32(index))
            if RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                failed.insert(action.rawValue)
            }
        }
        if self.failed != failed { self.failed = failed }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                guard HotkeyAction.allCases.indices.contains(index) else { return }
                switch HotkeyAction.allCases[index] {
                case .playPause: MediaService.shared.togglePlayPause()
                case .next: MediaService.shared.next()
                case .previous: MediaService.shared.previous()
                case .toggleIsland: NotchController.shared.toggle()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    // MARK: Building a Hotkey from a key event

    static func hotkey(from event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Shift alone would hijack ordinary typing.
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        label += keyName(event)
        return Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbon, label: label)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}

/// A button that records the next key combination pressed.
struct HotkeyRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var center = HotkeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Group {
                    if recording {
                        Text("Press a shortcut…")
                    } else if let hotkey = center.hotkey(for: action) {
                        Text(verbatim: hotkey.label)
                    } else {
                        Text("Record")
                    }
                }
                .frame(minWidth: 110)
            }
            if center.failed.contains(action.rawValue), !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text("This shortcut is already used by macOS or another app."))
            }
            if center.hotkey(for: action) != nil, !recording {
                Button {
                    center.set(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Remove shortcut"))
                .accessibilityLabel(Text("Remove shortcut"))
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let hotkey = HotkeyCenter.hotkey(from: event) {
                center.set(hotkey, for: action)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
