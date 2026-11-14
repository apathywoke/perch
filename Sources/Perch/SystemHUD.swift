import AppKit
import ApplicationServices
import CoreAudio
import os
import PerchCore
import SwiftUI

struct HUDState: Equatable {
    enum Kind { case volume, brightness }
    var kind: Kind
    var value: Double
    var muted = false
}

extension HUDState {
    var level: Double { kind == .volume && muted ? 0 : value }

    /// What VoiceOver says, e.g. "Volume 50%".
    var spokenDescription: String {
        let name = NSLocalizedString(kind == .volume ? "Volume" : "Brightness", comment: "")
        if level <= 0.001, kind == .volume { return name + ", " + NSLocalizedString("Muted", comment: "") }
        return "\(name) \(Int((level * 100).rounded()))%"
    }
}

extension HUDStyle {
    var title: LocalizedStringKey {
        switch self {
        case .beside: "Beside the notch"
        case .below: "Below the notch"
        }
    }
}

/// Replaces the system volume and brightness indicators.
///
/// The only way to keep macOS from drawing its own indicator is to take the
/// volume / brightness key presses before the system sees them and apply the
/// change ourselves. That needs an event tap, and an event tap needs the
/// Accessibility permission. The tap is registered for system-defined events
/// only (media keys); ordinary keystrokes are never delivered to it.
final class SystemHUD: ObservableObject {
    static let shared = SystemHUD()
    /// Local diagnostics only (Console.app); nothing leaves the Mac.
    static let log = Logger(subsystem: "dev.perch.Perch", category: "hud")

    @Published private(set) var trusted = AXIsProcessTrusted()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustTimer: Timer?
    private var lastLoggedState = ""

    private static let systemDefined: UInt32 = 14 // NX_SYSDEFINED
    private var accessObserver: NSObjectProtocol?

    init() {
        // Posted whenever the Accessibility list changes. If access is revoked while
        // the tap is running, it has to go at once, not on the next settings change.
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new state is readable a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.sync() }
        }
    }

    /// Starts or stops the key interception to match the settings and the permission.
    func sync() {
        let nowTrusted = AXIsProcessTrusted()
        if trusted != nowTrusted { trusted = nowTrusted }
        let wanted = Pref.bool(Pref.hudEnabled)

        let state = "wanted=\(wanted) trusted=\(trusted)"
        if state != lastLoggedState {
            lastLoggedState = state
            Self.log.notice("indicators \(state, privacy: .public)")
        }
        if wanted, trusted { startTap() } else { stopTap() }

        if wanted, !trusted, trustTimer == nil {
            // The permission is granted in System Settings; notice when that happens.
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.sync() }
            RunLoop.main.add(timer, forMode: .common)
            trustTimer = timer
        } else if !wanted || trusted {
            trustTimer?.invalidate()
            trustTimer = nil
        }
    }

    func diagnosticRows() -> [(String, String)] {
        [
            ("Enabled", Pref.bool(Pref.hudEnabled) ? "yes" : "no"),
            ("Accessibility access", trusted ? "granted" : "not granted"),
            ("Key interception", tap != nil ? "active" : "off"),
            ("Volume / brightness", "\(Pref.bool(Pref.hudVolume) ? "on" : "off") / \(Pref.bool(Pref.hudBrightness) ? "on" : "off")"),
        ]
    }

    /// Shows the system permission dialog once, on the first launch with the
    /// indicators on. After that the Settings pane is the way to grant it.
    func askOnFirstLaunch() {
        guard Pref.bool(Pref.hudEnabled), !AXIsProcessTrusted(), !Pref.bool(Pref.hudAskedForAccess) else { return }
        Pref.set(true, Pref.hudAskedForAccess)
        requestAccess()
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        sync()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Event tap

    private func startTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefined)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            SystemHUD.shared.handle(type: type, event: event)
        }, userInfo: nil) else {
            Self.log.error("event tap could not be created")
            return
        }
        Self.log.notice("event tap created")
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func stopTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if AXIsProcessTrusted() {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                DispatchQueue.main.async { self.sync() }
            }
            return pass
        }
        guard type.rawValue == Self.systemDefined, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return pass }

        let code = (key.data1 & 0xFFFF_0000) >> 16
        Self.log.debug("media key \(code)")
        let down = ((key.data1 & 0xFF00) >> 8) == 0xA
        let flags = key.modifierFlags
        // ⌥ + key opens the matching System Settings pane; leave that to macOS.
        if flags.contains(.option), !flags.contains(.shift) { return pass }
        let step = (flags.contains(.option) && flags.contains(.shift)) ? 1.0 / 64 : 1.0 / 16

        switch code {
        case 0, 1, 7: // sound up, sound down, mute
            guard Pref.bool(Pref.hudVolume), let device = Audio.outputDevice(), Audio.canSetVolume(device),
                  code != 7 || Audio.hasMute(device) else { return pass }
            if down { changeVolume(device: device, code: code, step: Float(step)) }
            return nil
        case 2, 3: // brightness up, down
            guard Pref.bool(Pref.hudBrightness), let display = Brightness.display(),
                  let current = Brightness.get(display) else { return pass }
            if down {
                let value = min(max(current + Float(code == 2 ? step : -step), 0), 1)
                Brightness.set(display, value)
                NotchController.shared.showHUD(HUDState(kind: .brightness, value: Double(value)))
            }
            return nil
        default:
            return pass
        }
    }

    private func changeVolume(device: AudioObjectID, code: Int, step: Float) {
        var volume = Audio.volume(device) ?? 0
        var muted = Audio.isMuted(device)
        if code == 7 {
            muted.toggle()
        } else {
            volume = VolumeMath.stepped(volume, step: step, up: code == 0)
            Audio.setVolume(device, volume)
            muted = false
        }
        Audio.setMuted(device, muted)
        NotchController.shared.showHUD(HUDState(kind: .volume, value: Double(volume), muted: muted))
    }
}

// MARK: - Volume (public CoreAudio API)

private enum Audio {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 'vmvc': the device's overall volume, the same value the system slider shows.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func canSetVolume(_ device: AudioObjectID) -> Bool {
        var addr = address(virtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &addr)
            && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static func volume(_ device: AudioObjectID) -> Float? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(virtualMainVolume)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float) {
        var value = value
        var addr = address(virtualMainVolume)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func hasMute(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &addr)
            && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &addr) else { return }
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: - Brightness (private DisplayServices framework; there is no public API)

private enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (GetFn, SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFn.self), unsafeBitCast(set, to: SetFn.self))
    }()

    /// The built-in display; external monitors are left to the system.
    static func display() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let (get, _) = functions else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) {
        guard let (_, set) = functions else { return }
        _ = set(display, value)
    }
}
