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
                if let mail = environment.graphs[accountID]?.mail, let pause = mail.classificationPause {
                    HStack(alignment: .firstTextBaseline, spacing: MailTheme.Spacing.sm) {
                        Label(Self.pauseText(pause), systemImage: MailTheme.Symbol.warning)
                            .textStyle(MailTheme.Typography.caption)
                            .foregroundStyle(MailTheme.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Resume") {
                            Task { await mail.classification?.resume() }
                        }
                        .buttonStyle(SettingsOutlineButtonStyle())
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
            SettingsSection(title: "Recent activity") {
                let recent = Self.recentActivity(
                    environment.graphs[accountID]?.mail.classificationActivity ?? [],
                    mailboxIDs: Set(item.domain.mailboxIDs)
                )
                SettingsCard {
                    if recent.isEmpty {
                        SettingsRow(title: "No activity yet", note: Self.emptyActivityText)
                    } else {
                        ForEach(recent) { record in
                            WorkflowActivityRow(record: record, labels: labels)
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

    /// Why classification stopped for this session. Changing the AI Gateway
    /// account, gateway or model resumes it on the next new mail; saving a token
    /// resumes it at once.
    nonisolated static func pauseText(_ error: AIGatewayError) -> String {
        "Classification is paused: \(AIGatewaySettings.message(for: error)) Fix it in AI Gateway settings, then resume."
    }

    nonisolated static let activityLimit = 20
    nonisolated static let emptyActivityText = "New mail this Mac classifies for this domain appears here. "
        + "The log is kept only while Herald is running."

    /// This domain's records, newest first, at most ``activityLimit``.
    nonisolated static func recentActivity(
        _ records: [ClassificationRecord], mailboxIDs: Set<String>, limit: Int = activityLimit
    ) -> [ClassificationRecord] {
        Array(records.reversed().filter { $0.mailboxID.map(mailboxIDs.contains) ?? false }.prefix(limit))
    }

    /// The outcome in plain English, for everything but an applied tag (which
    /// draws as its chip).
    nonisolated static func outcomeText(_ outcome: ClassificationOutcome) -> String {
        switch outcome {
        case .labelled(_, let name): "Tagged \(name)"
        case .none: "No tag"
        case .skipped(let reason): "Skipped — \(skipText(reason))"
        case .failed(let code): "Failed — \(failureText(code))"
        }
    }

    nonisolated static func skipText(_ reason: ClassificationSkipReason) -> String {
        switch reason {
        case .threadLabelled: "the conversation already has a tag"
        case .notFirstInbound: "not the first message of the conversation"
        case .beforeEnabled: "arrived before classification was turned on"
        case .hourlyCap: "the hourly limit was reached"
        case .labelledMeanwhile: "the conversation was tagged meanwhile"
        case .paused: "classification was paused"
        case .notInbound, .notInbox, .domainOff, .noRules, .alreadyAttempted: "not eligible"
        }
    }

    /// Maps the engine's short failure codes; an unknown one stays generic.
    nonisolated static func failureText(_ code: String) -> String {
        switch code {
        case "threadCheck": return "couldn’t check the conversation on the server"
        case "labelWrite": return "couldn’t apply the tag"
        case "unauthorized": return "the AI Gateway token was rejected"
        case "insufficientCredits": return "the Cloudflare account is out of credits"
        case "modelNotAllowed": return "the model isn’t available on this gateway"
        case "blocked": return "Cloudflare blocked the request"
        case "missingToken": return "no AI Gateway token is saved"
        case "invalidConfiguration": return "the AI Gateway settings are incomplete"
        case "rateLimited": return "the gateway is rate limiting requests"
        case "malformedResponse": return "the model’s answer couldn’t be read"
        case "transport": return "couldn’t reach the gateway"
        default:
            if code.hasPrefix("http"), let status = Int(code.dropFirst(4)) { return "the gateway answered \(status)" }
            return "an unexpected error"
        }
    }

    /// `workers-ai/@cf/meta/llama-3.1-8b-instruct-fp8` → `llama-3.1-8b-instruct-fp8`.
    nonisolated static func modelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
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

/// One activity-log entry: subject, then when and with which model; the tag
/// chip (or the plain-English outcome) on the right.
private struct WorkflowActivityRow: View {
    let record: ClassificationRecord
    let labels: [MailLabel]

    var body: some View {
        SettingsRow(title: record.subject.isEmpty ? "(No subject)" : record.subject, note: note) {
            outcome
        }
        .accessibilityElement(children: .combine)
    }

    private var note: String {
        let time = record.date.formatted(date: .abbreviated, time: .shortened)
        guard let model = record.model else { return time }
        return "\(time) · \(DomainWorkflowsSettingsPage.modelName(model))"
    }

    @ViewBuilder private var outcome: some View {
        if case .labelled(let labelID, _) = record.outcome, let label = labels.first(where: { $0.id == labelID }) {
            LabelChip(label: label)
        } else {
            Text(DomainWorkflowsSettingsPage.outcomeText(record.outcome))
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(Self.isProblem(record.outcome) ? MailTheme.Color.warn : MailTheme.Color.ink3)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func isProblem(_ outcome: ClassificationOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }
}
