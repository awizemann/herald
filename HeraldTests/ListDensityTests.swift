import Foundation
import Testing

@testable import Herald

/// `ListDensity`: default, round-trip, storage key, and resilience to a stored
/// value this build doesn't recognise.
@Suite("List density", .scratchDefaults)
struct ListDensityTests {
    private func makeDefaults() -> UserDefaults { ScratchDefaults.make() }

    @Test("Fresh defaults default to comfortable")
    func freshDefaultsAreComfortable() {
        #expect(ListDensity.current(in: makeDefaults()) == .comfortable)
    }

    @Test("Setting compact round-trips")
    func compactRoundTrips() {
        let defaults = makeDefaults()
        ListDensity.set(.compact, in: defaults)
        #expect(ListDensity.current(in: defaults) == .compact)
    }

    @Test("Storage key is list.density exactly")
    func storageKeyShape() {
        #expect(ListDensity.storageKey == "list.density")
    }

    @Test("An unrecognised stored value falls back to comfortable rather than crashing")
    func unrecognisedValueFallsBackToComfortable() {
        let defaults = makeDefaults()
        defaults.set("cozy", forKey: ListDensity.storageKey)
        #expect(ListDensity.current(in: defaults) == .comfortable)
    }
}
