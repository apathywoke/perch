import Foundation

public enum TimeText {
    /// "3:07", or "1:02:03" past an hour. Negative or invalid values show as "0:00".
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 359_999).rounded(.down)) // cap at 99:59:59
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

public enum VolumeMath {
    /// The level after one press of a volume key. Levels snap to the step grid, so
    /// presses land on the same values as the system's, and an off-grid level
    /// never moves by more than one step.
    public static func stepped(_ volume: Float, step: Float, up: Bool) -> Float {
        guard step > 0, volume.isFinite else { return volume }
        let position = volume / step
        let tolerance: Float = 0.01 // absorbs rounding noise from the audio driver
        let target = up ? (position + tolerance).rounded(.down) + 1 : (position - tolerance).rounded(.up) - 1
        return min(max(target * step, 0), 1)
    }
}
