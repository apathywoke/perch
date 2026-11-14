import Testing
@testable import PerchCore

@Suite("Versions")
struct VersionTests {
    @Test func readsTagsAndPlainVersions() {
        #expect(AppVersion("v0.1.0")?.parts == [0, 1, 0])
        #expect(AppVersion("0.2")?.parts == [0, 2])
        #expect(AppVersion(" 1.10.3 ")?.parts == [1, 10, 3])
        #expect(AppVersion("1.2.3-beta.1")?.parts == [1, 2, 3])
    }

    @Test(arguments: ["", "v", "1..2", "1.x", "abc", "1.2.3.4.5", "-1.0", "١.٢"])
    func rejectsNonsense(text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func missingPartsCountAsZero() {
        #expect(AppVersion("0.1") == AppVersion("0.1.0"))
        #expect(!(AppVersion("0.1")! < AppVersion("0.1.0")!))
    }

    @Test func comparesNumbersNotText() {
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("0.1.0")! < AppVersion("v0.1.1")!)
        #expect(AppVersion("1.0")! > AppVersion("0.99.99")!)
        #expect(!(AppVersion("0.2.0")! < AppVersion("0.1.9")!))
    }
}
