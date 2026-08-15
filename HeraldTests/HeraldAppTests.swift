import Testing
@testable import Herald

@Suite struct HeraldAppTests {
    @Test func appTargetLinksKit() { #expect(true) }
}
