import Foundation

/// The battery as the system reports it.
public struct PowerState: Equatable {
    /// On the power adapter.
    public var onAC: Bool
    /// Charge, from 0 to 1.
    public var level: Double
    public var charging: Bool

    public init(onAC: Bool, level: Double, charging: Bool) {
        self.onAC = onAC
        self.level = level
        self.charging = charging
    }
}

/// What the island says about the battery.
public enum PowerChange: Equatable {
    case pluggedIn(level: Double)
    case unplugged(level: Double)
    case low(level: Double)
}

public enum PowerEvents {
    /// Charge levels at which a running-low warning appears, once each, on battery.
    public static let lowLevels: [Double] = [0.2, 0.1, 0.05]

    /// The change worth showing between two readings, if any. The first reading
    /// (when Perch starts) is never shown.
    public static func change(from old: PowerState?, to new: PowerState) -> PowerChange? {
        guard let old else { return nil }
        if new.onAC != old.onAC {
            return new.onAC ? .pluggedIn(level: new.level) : .unplugged(level: new.level)
        }
        if !new.onAC, lowLevels.contains(where: { old.level > $0 && new.level <= $0 }) {
            return .low(level: new.level)
        }
        return nil
    }
}

/// How a Focus looks in the island, by its name. Focus names come from the
/// menu bar in the system language; the built-in ones are recognised in
/// English and Russian, others get the moon.
public enum FocusLook: Equatable {
    case doNotDisturb, sleep, work, personal, driving, fitness, gaming, mindfulness, reading, other

    public init(name: String) {
        let name = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("disturb", "беспоко") { self = .doNotDisturb }
        else if has("sleep", "сон", "сна") { self = .sleep }
        else if has("work", "работ") { self = .work }
        else if has("personal", "личн") { self = .personal }
        else if has("driv", "вожден", "за рулём", "за рулем") { self = .driving }
        else if has("fitness", "фитнес") { self = .fitness }
        else if has("gaming", "game", "игр") { self = .gaming }
        else if has("mindful", "осознан") { self = .mindfulness }
        else if has("reading", "чтени") { self = .reading }
        else { self = .other }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .doNotDisturb, .other: "moon.fill"
        case .sleep: "bed.double.fill"
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        case .driving: "car.fill"
        case .fitness: "figure.run"
        case .gaming: "gamecontroller.fill"
        case .mindfulness: "brain.head.profile"
        case .reading: "book.fill"
        }
    }

    /// The Focus colour, as red, green, blue from 0 to 1 (close to the system's own).
    public var color: (red: Double, green: Double, blue: Double) {
        switch self {
        case .doNotDisturb, .other: (0.49, 0.43, 1.0)
        case .sleep: (0.36, 0.84, 0.78)
        case .work: (0.25, 0.68, 1.0)
        case .personal: (0.75, 0.45, 1.0)
        case .driving: (1.0, 0.62, 0.2)
        case .fitness: (0.55, 0.88, 0.3)
        case .gaming: (0.33, 0.55, 1.0)
        case .mindfulness: (0.42, 0.85, 0.85)
        case .reading: (1.0, 0.72, 0.25)
        }
    }
}

/// Reads the Focus from what Control Center shows in the menu bar: while a
/// Focus is on, its menu bar item is named after the Focus instead of after
/// Control Center itself, and a separate Focus item appears.
public enum FocusReading {
    /// The Focus on, by name, or nil when none is.
    /// - Parameters:
    ///   - controlCenterItem: description of Control Center's own menu bar item.
    ///   - controlCenterName: Control Center's name in the system language.
    ///   - focusItemShown: the separate Focus menu bar item is there.
    public static func focus(controlCenterItem: String?, controlCenterName: String?, focusItemShown: Bool) -> String? {
        guard focusItemShown, let item = controlCenterItem?.trimmingCharacters(in: .whitespaces), !item.isEmpty,
              item != controlCenterName else { return nil }
        return item
    }
}
