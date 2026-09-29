import HeraldKit
import SwiftUI

/// Settings › {domain} › Workflows: "Classify new mail" — which workspace
/// labels the AI classifier may apply to this domain's new conversations, and
/// how each is described to the model. Stored on this Mac only
/// (``WorkflowPreferences``); every write goes through
/// ``AppEnvironment/updateDomainPreferences(accountID:reloads:_:)`` so the page
/// repaints, never straight into `UserDefaults`.
struct DomainWorkflowsSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem
    let accountID: Account.ID
    let breadcrumb: String

    /// Read once on appear (a Keychain read), not on every body pass. The page
    /// re-appears — and re-reads — after a trip to the AI Gateway page.
    @State private var isGatewayConfigured = false

    static let labelsCaption = "Tags are created in the HQBase web admin — Herald can only apply existing tags. "
        + "Each conversation is tagged once, on its first incoming message, and never re-tagged."
    static let descriptionPrompt = "What belongs here — and what doesn’t, where tags overlap"

    var body: some View {
        let defaults = environment.domainPreferencesObserved()
        let labels = environment.graphs[accountID]?.mail.labels ?? []
        let enabled = WorkflowPreferences.isEnabled(accountID: accountID, domainID: item.id, in: defaults)
        SettingsPage(title: DomainSettingsPage.workflows.title, breadcrumb: breadcrumb) {
            SettingsSection(title: "Classify new mail") {
                SettingsCard {
                    SettingsRow(
                        title: "Classify new mail",
                        note: enabledNote(enabled: enabled, defaults: defaults),
                        source: .herald
                    ) {
                        Toggle("Classify new mail", isOn: enabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!isGatewayConfigured && !enabled)
                            .accessibilityIdentifier(AccessibilityID.Settings.workflowClassify)
                    }
                    if !isGatewayConfigured {
                        SettingsRow(
                            title: "AI Gateway not set up",
                            note: "Classification sends new mail to your Cloudflare AI Gateway. Set it up first."
                        ) {
                            Button("Open AI Gateway Settings") {
                                environment.settingsRoute = .aiGateway
                            }
                            .buttonStyle(SettingsOutlineButtonStyle())
                            .accessibilityIdentifier(AccessibilityID.Settings.workflowOpenAIGateway)
                        }
                    }
                }
                if let warning = WorkflowPreferences.setupWarning(
                    accountID: accountID, domainID: item.id, labels: labels, in: defaults
                ) {
                    Label(Self.warningText(warning), systemImage: MailTheme.Symbol.warning)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.Settings.workflowWarning)
                }
            }
            SettingsSection(title: "Tags") {
                Text(Self.labelsCaption)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsCard {
                    if labels.isEmpty {
                        SettingsRow(title: "No tags", note: "This workspace has no tags yet.")
                    } else {
                        ForEach(labels) { label in
                            WorkflowLabelRow(
                                label: label,
                                accountID: accountID,
                                domainID: item.id,
                                stored: WorkflowPreferences.labelRule(
                                    labelID: label.id, accountID: accountID, domainID: item.id, in: defaults
                                )
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            isGatewayConfigured = AIGatewaySettings.isConfigured(in: environment.defaults, secrets: KeychainStore())
        }
    }

    private func enabledNote(enabled: Bool, defaults: UserDefaults) -> String {
        guard enabled, let since = WorkflowPreferences.enabledAt(accountID: accountID, domainID: item.id, in: defaults) else {
            return "Off. Only mail that arrives after you turn this on is classified."
        }
        return "Classifying mail received since \(since.formatted(date: .abbreviated, time: .shortened))."
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: {
                WorkflowPreferences.isEnabled(
                    accountID: accountID, domainID: item.id, in: environment.domainPreferencesObserved()
                )
            },
            set: { newValue in
                Task {
                    await environment.updateDomainPreferences(accountID: accountID, reloads: false) { defaults in
                        WorkflowPreferences.setEnabled(newValue, accountID: accountID, domainID: item.id, in: defaults)
                    }
                }
            }
        )
    }

    /// Pure so the wording is assertable without a rendered page.
    nonisolated static func warningText(_ warning: WorkflowSetupWarning) -> String {
        switch warning {
        case .noLabelsIncluded:
            "No tags are included, so nothing will be classified."
        case .missingDescriptions(let names):
            "Add a description to \(names.joined(separator: ", ")) — tags without one are skipped."
        }
    }
}

/// One label: include checkbox, chip, one-line description. The description is
/// a local draft written through on every change, so typing never waits on the
/// async write's repaint.
private struct WorkflowLabelRow: View {
    @Environment(AppEnvironment.self) private var environment
    let label: MailLabel
    let accountID: Account.ID
    let domainID: MailDomain.ID
    let stored: WorkflowLabelRule

    @State private var draft: String?

    var body: some View {
        HStack(spacing: MailTheme.Spacing.md) {
            Toggle(isOn: Binding(get: { stored.included }, set: { write(included: $0, description: currentDescription) })) {
                LabelChip(label: label)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include \(label.name)")
            .accessibilityIdentifier(AccessibilityID.Settings.workflowIncludePrefix + label.id)
            TextField(
                "",
                text: Binding(
                    get: { currentDescription },
                    set: { newValue in
                        draft = newValue
                        write(included: stored.included, description: newValue)
                    }
                ),
                prompt: Text(DomainWorkflowsSettingsPage.descriptionPrompt)
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .font(MailTheme.Typography.meta.font)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Description for \(label.name)")
            .accessibilityIdentifier(AccessibilityID.Settings.workflowDescriptionPrefix + label.id)
        }
        .padding(.vertical, MailTheme.Spacing.md)
        .padding(.horizontal, MailTheme.Spacing.lg)
    }

    private var currentDescription: String { draft ?? stored.description }

    private func write(included: Bool, description: String) {
        let rule = WorkflowLabelRule(included: included, description: description)
        Task {
            await environment.updateDomainPreferences(accountID: accountID, reloads: false) { defaults in
                WorkflowPreferences.setLabelRule(rule, labelID: label.id, accountID: accountID, domainID: domainID, in: defaults)
            }
        }
    }
}
