import CoreGraphics
import Testing
@testable import PerchCore

@Suite("Island geometry")
struct LayoutTests {
    /// MacBook Air 13" M2 at the default resolution.
    private let notch = CGSize(width: 209, height: 38)

    @Test func notchIsTheGapBetweenTheMenuBarAreas() {
        let geometry = NotchLayout.geometry(screenWidth: 1710, safeAreaTop: 38, leftAuxWidth: 751, rightAuxWidth: 750)
        #expect(geometry == .init(hasNotch: true, notch: CGSize(width: 209, height: 38)))
    }

    @Test func noSafeAreaMeansNoNotch() {
        let geometry = NotchLayout.geometry(screenWidth: 1920, safeAreaTop: 0, leftAuxWidth: nil, rightAuxWidth: nil)
        #expect(!geometry.hasNotch)
        #expect(geometry.notch == NotchLayout.virtualNotch)
    }

    @Test(arguments: [(CGFloat?.none, CGFloat?.none), (850, 850), (100, 100)])
    func implausibleMeasurementsFallBackToADefaultWidth(left: CGFloat?, right: CGFloat?) {
        let geometry = NotchLayout.geometry(screenWidth: 1710, safeAreaTop: 38, leftAuxWidth: left, rightAuxWidth: right)
        #expect(geometry.notch.width == 200)
    }

    @Test func idleIslandIsExactlyTheNotch() {
        #expect(NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: false, scale: 1) == notch)
    }

    @Test func musicAddsAWingOnEachSide() {
        let size = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: true, scale: 1)
        #expect(size == CGSize(width: 209 + 2 * 42, height: 38))
    }

    @Test func expandedFollowsTheSizeSetting() {
        let normal = NotchLayout.size(phase: .expanded, notch: notch, hasNotch: true, active: true, scale: 1)
        #expect(normal == CGSize(width: 368, height: 178))
        let large = NotchLayout.size(phase: .expanded, notch: notch, hasNotch: true, active: true, scale: 1.25)
        #expect(large == CGSize(width: 460, height: 222.5))
    }

    @Test func artworkFitsBesideTheNotch() {
        for scale in [0.85, 1, 1.35] as [CGFloat] {
            let player = NotchLayout.player(notch: notch, hasNotch: true, scale: scale)
            let notchLeftEdge = (player.width - notch.width) / 2
            #expect(player.inset + player.art <= notchLeftEdge)
            #expect(player.textTop >= notch.height) // text never hides behind the camera
        }
    }

    @Test func playerRowsAreEvenlySpaced() {
        let player = NotchLayout.player(notch: notch, hasNotch: true, scale: 1)
        #expect(player.artTop == 18)
        #expect(player.textTop == 44)
        #expect(player.scrubberCenter == 94)
        #expect(player.controlsCenter == 134)
    }

    @Test func expandedIsNeverNarrowerThanTheNotch() {
        let wide = CGSize(width: 400, height: 38)
        let size = NotchLayout.size(phase: .expanded, notch: wide, hasNotch: true, active: true, scale: 0.85)
        #expect(abs(size.width - 532.6) < 0.01)
    }

    @Test func expandedWithoutANotchStartsAtTheTop() {
        let player = NotchLayout.player(notch: NotchLayout.virtualNotch, hasNotch: false, scale: 1)
        #expect(player.textTop == 28)
        #expect(player.height == 178)
    }

    @Test func pointerOnTheIslandMakesItSwell() {
        let idle = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: false, scale: 1, swell: true)
        #expect(idle == CGSize(width: 209 + 26, height: 38 + 7))
        let playing = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: true, scale: 1, swell: true)
        #expect(playing == CGSize(width: 293 + 26, height: 38 + 7))
    }

    @Test func onlyTheCollapsedIslandSwells() {
        let card = NotchLayout.size(phase: .peek, notch: notch, hasNotch: true, active: true, scale: 1, swell: true)
        #expect(card == CGSize(width: 349, height: 82))
        let indicator = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: true, scale: 1,
                                         hud: .beside, swell: true)
        #expect(indicator == CGSize(width: 401, height: 38))
    }

    @Test func trackCardNeedsMusic() {
        #expect(NotchLayout.size(phase: .peek, notch: notch, hasNotch: true, active: false, scale: 1) == notch)
        let card = NotchLayout.size(phase: .peek, notch: notch, hasNotch: true, active: true, scale: 1)
        #expect(card == CGSize(width: 349, height: 38 + 44))
    }

    @Test func indicatorBesideTheNotch() {
        let size = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: true, scale: 1, hud: .beside)
        #expect(size == CGSize(width: 209 + 192, height: 38))
    }

    @Test func indicatorBelowTheNotch() {
        let size = NotchLayout.size(phase: .collapsed, notch: notch, hasNotch: true, active: true, scale: 1, hud: .below)
        #expect(size == CGSize(width: 330, height: 38 + 36))
    }

    @Test func indicatorWithoutANotch() {
        let size = NotchLayout.size(phase: .collapsed, notch: NotchLayout.virtualNotch, hasNotch: false, active: false,
                                    scale: 1, hud: .beside)
        #expect(size == CGSize(width: 290, height: 32))
    }

    @Test func expandedPlayerAddsARowForAnIndicator() {
        let size = NotchLayout.size(phase: .expanded, notch: notch, hasNotch: true, active: true, scale: 1, hud: .below)
        #expect(size == CGSize(width: 368, height: 178 + 34))
    }
}

@Suite("Formatting and volume steps")
struct FormattingTests {
    @Test(arguments: zip(
        [0, 5.9, 59.99, 60, 61.5, 3599, 3600, 3661, -4, .nan, .infinity] as [Double],
        ["0:00", "0:05", "0:59", "1:00", "1:01", "59:59", "1:00:00", "1:01:01", "0:00", "0:00", "0:00"]
    ))
    func formatsTime(seconds: Double, expected: String) {
        #expect(TimeText.format(seconds) == expected)
    }

    @Test func volumeMovesOneStepOnTheGrid() {
        #expect(VolumeMath.stepped(0.5, step: 1.0 / 16, up: true) == 0.5625)
        #expect(VolumeMath.stepped(0.5, step: 1.0 / 16, up: false) == 0.4375)
    }

    @Test func offGridVolumeMovesToTheNeighbouringStep() {
        #expect(VolumeMath.stepped(0.53, step: 1.0 / 16, up: true) == 0.5625)
        #expect(VolumeMath.stepped(0.53, step: 1.0 / 16, up: false) == 0.5)
    }

    @Test func volumeStaysBetweenZeroAndOne() {
        #expect(VolumeMath.stepped(1, step: 1.0 / 16, up: true) == 1)
        #expect(VolumeMath.stepped(0, step: 1.0 / 16, up: false) == 0)
        #expect(VolumeMath.stepped(0.98, step: 1.0 / 16, up: true) == 1)
    }

    @Test func roundingNoiseDoesNotSkipAStep() {
        #expect(VolumeMath.stepped(0.5625 + 1e-6, step: 1.0 / 16, up: true) == 0.625)
        #expect(VolumeMath.stepped(0.5625 - 1e-6, step: 1.0 / 16, up: false) == 0.5)
    }

    @Test func fineStepsWork() {
        #expect(VolumeMath.stepped(0.5, step: 1.0 / 64, up: true) == 0.515625)
    }
}
