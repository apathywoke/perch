import AppKit
import CoreAudio

/// The system sound output, shown and switched from the island.
/// Uses only the public CoreAudio API and needs no permission.
final class AudioOutputs: NSObject, ObservableObject {
    static let shared = AudioOutputs()

    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let transport: UInt32
    }

    @Published private(set) var current: Device?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refresh()
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let device = Self.defaultOutput().flatMap(Self.device(for:))
        if device != current { current = device }
    }

    /// SF Symbol for the current output: a laptop for the speakers, AirPods, headphones…
    var symbol: String { Self.symbol(for: current) }

    // MARK: Menu

    func showMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: NSLocalizedString("Audio output", comment: ""), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let devices = Self.outputDevices()
        if devices.isEmpty {
            let none = NSMenuItem(title: NSLocalizedString("No output devices", comment: ""), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: device.id)
            item.image = NSImage(systemSymbolName: Self.symbol(for: device), accessibilityDescription: nil)
            item.state = device.id == current?.id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let number = item.representedObject as? NSNumber else { return }
        var id = AudioObjectID(number.uint32Value)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func outputDevices() -> [Device] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).compactMap(device(for:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func device(for id: AudioObjectID) -> Device? {
        var nameAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name) == noErr,
              let text = name?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
        return Device(id: id, name: text, transport: transport)
    }

    static func symbol(for device: Device?) -> String {
        guard let device else { return "speaker.wave.2" }
        let name = device.name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("headphone") || name.contains("наушник") { return "headphones" }
        switch device.transport {
        case UInt32(kAudioDeviceTransportTypeBuiltIn): return "laptopcomputer"
        case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE): return "headphones"
        case UInt32(kAudioDeviceTransportTypeAirPlay): return "airplayaudio"
        case UInt32(kAudioDeviceTransportTypeHDMI), UInt32(kAudioDeviceTransportTypeDisplayPort): return "tv"
        default: return "hifispeaker"
        }
    }
}
