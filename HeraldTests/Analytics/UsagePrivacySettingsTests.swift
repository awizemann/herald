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
        #expect(PrivacySettingsPane.accessibilityHint(isEnabled: nil) == "Loading current setting")
        #expect(PrivacySettingsPane.accessibilityHint(isEnabled: true).isEmpty)
        #expect(PrivacySettingsPane.accessibilityHint(isEnabled: false).isEmpty)
        for state in [true, false, nil] as [Bool?] {
            #expect(
                PrivacySettingsPane.accessibilityHint(isEnabled: state)
                    != PrivacySettingsPane.explanation
            )
        }
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
