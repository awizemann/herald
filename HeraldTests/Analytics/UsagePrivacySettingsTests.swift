import Testing
@testable import Herald

/// The Settings → Privacy opt-out. The pane is a thin `Form` around
/// ``UsagePrivacyModel``, so the model is what these tests drive.
@MainActor
struct UsagePrivacySettingsTests {
    @Test("The toggle shows the tracker's own state, not a guess")
    func loadMirrorsTracker() async {
        let tracker = RecordingUsageTracker()
        await tracker.setEnabled(false)
        let model = UsagePrivacyModel(usage: tracker)

        #expect(model.isEnabled == nil)
        await model.load()
        #expect(model.isEnabled == false)
    }

    @Test("Flipping the toggle off writes the opt-out through to the tracker")
    func toggleWritesThrough() async {
        let tracker = RecordingUsageTracker()
        let model = UsagePrivacyModel(usage: tracker)
        await model.load()
        #expect(model.isEnabled == true)

        await model.setEnabled(false)

        #expect(await tracker.enabledWrites == [false])
        // Re-read, not the value we just sent: the SDK is the source of truth.
        #expect(model.isEnabled == false)

        await model.setEnabled(true)
        #expect(await tracker.enabledWrites == [false, true])
        #expect(model.isEnabled == true)
    }

    /// The hint explains the INERT switch while the tracker's answer is on its
    /// way, and says nothing once it has arrived. Fails if the hint goes back to
    /// repeating the visible explanation, which VoiceOver then reads twice — once
    /// as the switch's hint and once as the caption beneath it.
    @Test("The switch's hint covers loading only, and never duplicates the caption")
    func hintIsLoadingOnlyAndNeverDuplicatesTheExplanation() {
        #expect(
            PrivacySettingsPane.accessibilityHint(isEnabled: nil, isAvailable: true)
                == "Loading current setting"
        )
        #expect(PrivacySettingsPane.accessibilityHint(isEnabled: true, isAvailable: true).isEmpty)
        #expect(PrivacySettingsPane.accessibilityHint(isEnabled: false, isAvailable: true).isEmpty)
        for state in [true, false, nil] as [Bool?] {
            #expect(
                PrivacySettingsPane.accessibilityHint(isEnabled: state, isAvailable: true)
                    != PrivacySettingsPane.explanation(isAvailable: true)
            )
        }
    }

    @Test("An unavailable build disables the switch and says why, in both the hint and the caption")
    func unavailableBuildDisablesAndExplains() async {
        let tracker = RecordingUsageTracker()
        await tracker.makeUnavailable()
        let model = UsagePrivacyModel(usage: tracker)

        #expect(model.isAvailable == false)
        await model.load()
        #expect(
            PrivacySettingsPane.accessibilityHint(isEnabled: model.isEnabled, isAvailable: false)
                == "Usage analytics aren't included in this build"
        )
        #expect(PrivacySettingsPane.explanation(isAvailable: false) == PrivacySettingsPane.unavailableExplanation)

        // Writing through an unavailable tracker is inert, and never manufactures
        // a "Saved" confirmation the build cannot back up.
        await model.setEnabled(true)
        #expect(model.confirmation == nil)
    }

    @Test("A keyed build confirms a successful write, unobtrusively")
    func keyedBuildConfirmsWrites() async {
        let tracker = RecordingUsageTracker()
        let model = UsagePrivacyModel(usage: tracker)
        await model.load()

        await model.setEnabled(false)
        #expect(model.confirmation == "Analytics are off — nothing is sent.")

        await model.setEnabled(true)
        #expect(model.confirmation == "Saved.")
    }

    @Test("Opting out is never itself reported")
    func togglingRecordsNoEvent() async {
        let tracker = RecordingUsageTracker()
        let model = UsagePrivacyModel(usage: tracker)
        await model.load()

        await model.setEnabled(false)
        await model.setEnabled(true)

        #expect(await tracker.events.isEmpty)
    }
}
