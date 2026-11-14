import Testing
@testable import PerchCore

@Suite("Island events")
struct ActivitiesTests {
    private func power(_ ac: Bool, _ level: Double) -> PowerState {
        PowerState(onAC: ac, level: level, charging: ac && level < 1)
    }

    @Test func pluggingInAndOutIsShown() {
        #expect(PowerEvents.change(from: power(false, 0.5), to: power(true, 0.5)) == .pluggedIn(level: 0.5))
        #expect(PowerEvents.change(from: power(true, 0.8), to: power(false, 0.8)) == .unplugged(level: 0.8))
    }

    @Test func theFirstReadingIsNotShown() {
        #expect(PowerEvents.change(from: nil, to: power(true, 0.5)) == nil)
    }

    @Test func runningLowWarnsOncePerLevel() {
        #expect(PowerEvents.change(from: power(false, 0.21), to: power(false, 0.2)) == .low(level: 0.2))
        #expect(PowerEvents.change(from: power(false, 0.2), to: power(false, 0.19)) == nil)
        #expect(PowerEvents.change(from: power(false, 0.11), to: power(false, 0.1)) == .low(level: 0.1))
        #expect(PowerEvents.change(from: power(false, 0.5), to: power(false, 0.49)) == nil)
        // Charging past a level says nothing.
        #expect(PowerEvents.change(from: power(true, 0.19), to: power(true, 0.21)) == nil)
    }

    @Test func focusLooksByName() {
        #expect(FocusLook(name: "Do Not Disturb") == .doNotDisturb)
        #expect(FocusLook(name: "Не беспокоить") == .doNotDisturb)
        #expect(FocusLook(name: "Сон") == .sleep)
        #expect(FocusLook(name: "Work") == .work)
        #expect(FocusLook(name: "Вождение") == .driving)
        #expect(FocusLook(name: "Coding") == .other)
        #expect(FocusLook(name: "Coding").symbol == "moon.fill")
    }

    @Test func focusIsReadFromTheMenuBar() {
        #expect(FocusReading.focus(controlCenterItem: "Do Not Disturb", controlCenterName: "Control Center",
                                   focusItemShown: true) == "Do Not Disturb")
        #expect(FocusReading.focus(controlCenterItem: "Control Center", controlCenterName: "Control Center",
                                   focusItemShown: true) == nil)
        #expect(FocusReading.focus(controlCenterItem: "Control Center", controlCenterName: "Control Center",
                                   focusItemShown: false) == nil)
        #expect(FocusReading.focus(controlCenterItem: nil, controlCenterName: "Control Center",
                                   focusItemShown: true) == nil)
    }
}
