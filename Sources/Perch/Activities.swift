import AppKit
import ApplicationServices
import Combine
import CoreAudio
import CoreMediaIO
import IOKit.ps
import os
import PerchCore

/// Something that happened on the Mac, shown for a moment in the island.
struct IslandEvent: Equatable {
    enum Kind: Equatable {
        case focus(name: String, on: Bool)
        case power(PowerChange)
        case headphones(name: String, symbol: String, connected: Bool)
        case capsLock(on: Bool)
        case microphone(app: String?)
        case camera
    }

    let kind: Kind
    /// The same event again plays its animation again.
    let id = UUID()

    /// What VoiceOver says.
    var spokenDescription: String {
        func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
        switch kind {
        case .focus(let name, let on): return "\(name), " + switchText(on)
        case .power(.pluggedIn(let level)): return text("Charging") + " \(Int((level * 100).rounded()))%"
        case .power(.unplugged(let level)): return text("On battery") + " \(Int((level * 100).rounded()))%"
        case .power(.low(let level)): return text("Low battery") + " \(Int((level * 100).rounded()))%"
        case .headphones(let name, _, let connected): return "\(name), " + text(connected ? "Connected" : "Disconnected")
        case .capsLock(let on): return "Caps Lock, " + switchText(on)
        case .microphone(let app): return text("Microphone in use") + (app.map { ", \($0)" } ?? "")
        case .camera: return text("Camera in use")
        }
    }
}

/// "On" / "Off" as short as the island needs ("Вкл" / "Выкл"), apart from the
/// longer words Settings uses for the same English.
func switchText(_ on: Bool) -> String {
    on ? NSLocalizedString("switch.on", value: "On", comment: "Short: something is on")
       : NSLocalizedString("switch.off", value: "Off", comment: "Short: something is off")
}

/// The microphone and camera in use, shown as a dot on the island for as long as they are.
struct PrivacyUse: Equatable {
    var microphone = false
    var camera = false
    var any: Bool { microphone || camera }
}

/// Watches for the events the island shows. Each kind can be turned off in
/// Settings, and a watcher only runs while its kind is on. Nothing here needs
/// a permission beyond the Accessibility access the volume indicator already
/// has, and nothing leaves the Mac.
final class ActivityCenter {
    static let shared = ActivityCenter()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "events")

    private let focus = FocusWatcher()
    private let power = PowerWatcher()
    private let capsLock = CapsLockWatcher()
    private let privacy = PrivacyWatcher()
    private var lastOutput: AudioOutputs.Device?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        focus.onChange = { [weak self] old, new in
            switch (old, new) {
            case (nil, let name?): self?.post(.focus(name: name, on: true))
            case (let name?, nil): self?.post(.focus(name: name, on: false))
            case (_, let name?): self?.post(.focus(name: name, on: true))
            default: break
            }
        }
        power.onChange = { [weak self] change in self?.post(.power(change)) }
        capsLock.onChange = { [weak self] on in self?.post(.capsLock(on: on)) }
        privacy.onChange = { [weak self] use, started in
            NotchController.shared.setPrivacy(use)
            if let started { self?.post(started) }
        }

        lastOutput = AudioOutputs.shared.current
        AudioOutputs.shared.$current
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.outputChanged(to: $0) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        // Key monitors set up before Accessibility access was granted stay deaf: renew them.
        SystemHUD.shared.$trusted
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.capsLock.stop()
                self?.sync()
            }
            .store(in: &cancellables)
        sync()
    }

    /// Runs the watchers whose events are turned on, and only those.
    private func sync() {
        Pref.bool(Pref.eventFocus) ? focus.start() : focus.stop()
        Pref.bool(Pref.eventPower) ? power.start() : power.stop()
        Pref.bool(Pref.eventCapsLock) ? capsLock.start() : capsLock.stop()
        if Pref.bool(Pref.eventPrivacy) {
            privacy.start()
        } else {
            privacy.stop()
            NotchController.shared.setPrivacy(PrivacyUse())
        }
    }

    private func post(_ kind: IslandEvent.Kind) {
        NotchController.shared.showEvent(IslandEvent(kind: kind))
    }

    /// Headphones connecting become the sound output, and leaving hand it back.
    private func outputChanged(to device: AudioOutputs.Device?) {
        defer { lastOutput = device }
        guard Pref.bool(Pref.eventHeadphones), device?.id != lastOutput?.id else { return }
        if let device, Self.isHeadphones(device) {
            post(.headphones(name: device.name, symbol: AudioOutputs.symbol(for: device), connected: true))
        } else if let old = lastOutput, Self.isHeadphones(old) {
            post(.headphones(name: old.name, symbol: AudioOutputs.symbol(for: old), connected: false))
        }
    }

    private static func isHeadphones(_ device: AudioOutputs.Device) -> Bool {
        let symbol = AudioOutputs.symbol(for: device)
        return symbol.contains("airpods") || symbol.contains("headphones") || symbol.contains("beats")
            || device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

// MARK: - Focus

/// macOS has no public way to learn about Focus changes, but Control Center
/// shows the Focus in the menu bar, and that is readable with the
/// Accessibility access Perch already has. Read every 1.5 s off the main
/// thread; one small request to Control Center each time.
private final class FocusWatcher {
    /// Old and new Focus names; nil for none.
    var onChange: ((String?, String?) -> Void)?
    private let queue = DispatchQueue(label: "dev.perch.Perch.focus", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// The Focus last seen; nil until the first reading, which is not shown.
    private var last: String??

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.5, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.last = nil }
    }

    private func check() {
        guard AXIsProcessTrusted(), let now = Self.read() else { return }
        if let last, last != now {
            DispatchQueue.main.async { self.onChange?(last, now) }
        }
        last = .some(now)
    }

    /// The Focus on (nil for none), or nil when the menu bar could not be read.
    private static func read() -> String?? {
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return nil }
        let app = AXUIElementCreateApplication(center.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var controlCenterItem: String?
        var focusShown = false
        for item in items {
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &identifier)
            switch identifier as? String {
            case "com.apple.menuextra.controlcenter":
                var description: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &description)
                controlCenterItem = description as? String
            case "com.apple.menuextra.focusmode":
                focusShown = true
            default:
                break
            }
        }
        return .some(FocusReading.focus(controlCenterItem: controlCenterItem, controlCenterName: center.localizedName,
                                        focusItemShown: focusShown))
    }
}

// MARK: - Power

/// The battery, from IOKit's power source notifications. Macs without a battery say nothing.
private final class PowerWatcher {
    var onChange: ((PowerChange) -> Void)?
    private var source: CFRunLoopSource?
    private var last: PowerState?

    func start() {
        guard source == nil else { return }
        last = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
        last = nil
    }

    private func changed() {
        guard let now = Self.read() else { return }
        if let change = PowerEvents.change(from: last, to: now) { onChange?(change) }
        last = now
    }

    static func read() -> PowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            return PowerState(onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                              level: maximum > 0 ? min(1, current / maximum) : 0,
                              charging: (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false)
        }
        return nil
    }
}

// MARK: - Caps Lock

/// Caps Lock from modifier key changes. Only the modifier state is looked at,
/// never which keys are typed.
private final class CapsLockWatcher {
    var onChange: ((Bool) -> Void)?
    private var monitors: [Any] = []
    private var on = false

    func start() {
        guard monitors.isEmpty else { return }
        on = NSEvent.modifierFlags.contains(.capsLock)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.check(event.modifierFlags)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.check(event.modifierFlags)
            return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func check(_ flags: NSEvent.ModifierFlags) {
        let now = flags.contains(.capsLock)
        guard now != on else { return }
        on = now
        onChange?(now)
    }
}

// MARK: - Microphone and camera

/// Whether any app records from the microphone or uses a camera, from the
/// properties Core Audio and Core Media IO keep for every device. Nothing is
/// opened or recorded, so no permission is needed.
private final class PrivacyWatcher {
    /// The new state, and the event to show when something just started.
    var onChange: ((PrivacyUse, IslandEvent.Kind?) -> Void)?
    private var use = PrivacyUse()
    private var running = false
    private var input = AudioObjectID(kAudioObjectUnknown)
    private var cameras: [CMIOObjectID] = []
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private var cameraListListener: CMIOObjectPropertyListenerBlock?

    func start() {
        guard !running else { return }
        running = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        let systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.watchInput() }
        AudioObjectAddPropertyListenerBlock(system, &address, .main, systemListener)
        self.systemListener = systemListener

        var list = Self.cameraAddress(kCMIOHardwarePropertyDevices)
        let listListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.watchCameras() }
        }
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &list, .main, listListener)
        cameraListListener = listListener

        watchInput()
        watchCameras()
        use = current()
        onChange?(use, nil)
    }

    func stop() {
        guard running else { return }
        running = false
        unwatchInput()
        unwatchCameras()
        if let systemListener {
            var address = Self.audioAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        if let cameraListListener {
            var list = Self.cameraAddress(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &list, .main, cameraListListener)
        }
        systemListener = nil
        cameraListListener = nil
        use = PrivacyUse()
    }

    private func update() {
        let now = current()
        guard now != use else { return }
        var started: IslandEvent.Kind?
        if now.camera, !use.camera {
            started = .camera
        } else if now.microphone, !use.microphone {
            started = .microphone(app: Self.recordingApp())
        }
        use = now
        onChange?(now, started)
    }

    private func current() -> PrivacyUse {
        PrivacyUse(microphone: input != kAudioObjectUnknown && Self.isRunning(input),
                   camera: cameras.contains(where: Self.isRunning(camera:)))
    }

    // Microphone

    private func watchInput() {
        let device = Self.defaultInput()
        if device != input {
            unwatchInput()
            input = device
            if device != kAudioObjectUnknown {
                var address = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }
                AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
                inputListener = listener
            }
        }
        update()
    }

    private func unwatchInput() {
        guard input != kAudioObjectUnknown, let inputListener else { return }
        var address = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(input, &address, .main, inputListener)
        self.inputListener = nil
        input = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultInput() -> AudioObjectID {
        var address = audioAddress(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func isRunning(_ device: AudioObjectID) -> Bool {
        var address = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// The app recording, by its name; helper processes count for their app.
    private static func recordingApp() -> String? {
        var address = audioAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            var running = audioAddress(kAudioProcessPropertyIsRunningInput)
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &running, 0, nil, &valueSize, &value) == noErr, value != 0 else { continue }
            var pidAddress = audioAddress(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != own,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.activationPolicy == .regular { return app.localizedName }
            // A helper (a browser's audio process): name the app it belongs to.
            if let id = app.bundleIdentifier,
               let owner = NSWorkspace.shared.runningApplications.first(where: {
                   $0.activationPolicy == .regular && ($0.bundleIdentifier.map { id.hasPrefix($0 + ".") } ?? false)
               }) {
                return owner.localizedName
            }
        }
        return nil
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // Camera

    private func watchCameras() {
        unwatchCameras()
        cameras = Self.cameraDevices()
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.update() }
        }
        for camera in cameras {
            var address = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(camera, &address, .main, listener)
        }
        cameraListener = listener
        update()
    }

    private func unwatchCameras() {
        guard let cameraListener else { return }
        for camera in cameras {
            var address = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(camera, &address, .main, cameraListener)
        }
        self.cameraListener = nil
        cameras = []
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = cameraAddress(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    private static func isRunning(camera: CMIOObjectID) -> Bool {
        var address = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
            && value != 0
    }

    private static func cameraAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}
