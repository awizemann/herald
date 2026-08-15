import Testing
@testable import HeraldKit

@Suite struct SmokeTests {
    @Test func moduleLoads() { #expect(HeraldKit.version == "0.1.0") }
}
