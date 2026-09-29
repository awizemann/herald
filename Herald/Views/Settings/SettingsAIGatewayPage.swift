import HeraldKit
import SwiftUI

/// Settings › Herald › AI Gateway: where classification requests go.
///
/// Every field writes straight through ``AIGatewaySettings``; the token goes to
/// the Keychain and is never read back into the UI — once saved the page only
/// says so, with Replace and Remove.
struct AIGatewaySettingsPage: View {
    let breadcrumb: String
    /// Built once on appear, not as an `@State` initial value: that would be
    /// re-evaluated (reading the Keychain) on every pass of the parent's body.
    @State private var model: AIGatewaySettingsModel?

    var body: some View {
        Group {
            if let model {
                AIGatewaySettingsForm(model: model, breadcrumb: breadcrumb)
            }
        }
        .onAppear {
            if model == nil { model = AIGatewaySettingsModel() }
        }
    }
}

private struct AIGatewaySettingsForm: View {
    @Bindable var model: AIGatewaySettingsModel
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: SettingsRoute.aiGateway.title, breadcrumb: breadcrumb) {
            SettingsSection(title: "Cloudflare") {
                SettingsCard {
                    SettingsRow(title: "Account ID", note: "Cloudflare dashboard › AI › AI Gateway — shown beside your account name.", source: .herald) {
                        idField("Account ID", text: $model.accountID, identifier: AccessibilityID.Settings.aiGatewayAccountID)
                    }
                    SettingsRow(title: "Gateway ID", note: "The name of the gateway you created under AI › AI Gateway.", source: .herald) {
                        idField("Gateway ID", text: $model.gatewayID, identifier: AccessibilityID.Settings.aiGatewayGatewayID)
                    }
                    SettingsRow(
                        title: "Gateway token",
                        note: "Open the gateway › Settings › Authentication and create a token. Stored in your login Keychain."
                    ) {
                        tokenControl
                    }
                }
            }
            SettingsSection(title: "Model") {
                SettingsCard {
                    SettingsRow(title: "Model", note: "Workers AI model used to classify mail.", source: .herald) {
                        Picker("Model", selection: $model.modelSelection) {
                            ForEach(AIGatewaySettings.curatedModels) { option in
                                Text(option.isRecommended ? "\(option.name) (recommended)" : option.name)
                                    .tag(option.id)
                            }
                            Divider()
                            Text("Custom…").tag(AIGatewaySettingsModel.customSelection)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Model")
                        .accessibilityIdentifier(AccessibilityID.Settings.aiGatewayModel)
                    }
                    if model.modelSelection == AIGatewaySettingsModel.customSelection {
                        SettingsRow(
                            title: "Custom model",
                            note: model.isCustomModelValid ? nil : "Enter a Workers AI model id starting with @cf/."
                        ) {
                            TextField("", text: $model.customModel, prompt: Text("@cf/…"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsLayout.idFieldWidth)
                                .font(MailTheme.Typography.meta.font)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Custom model id")
                                .accessibilityIdentifier(AccessibilityID.Settings.aiGatewayCustomModel)
                        }
                    }
                }
            }
            SettingsCard {
                SettingsRow(title: "Test connection", note: model.testResultText) {
                    Button(model.isTesting ? "Testing…" : "Test Connection") {
                        Task { await model.testConnection() }
                    }
                    .buttonStyle(SettingsOutlineButtonStyle())
                    .disabled(model.isTesting)
                    .accessibilityHint("Sends one short request to the gateway")
                    .accessibilityIdentifier(AccessibilityID.Settings.aiGatewayTest)
                }
            }
        }
    }

    private func idField(_ label: String, text: Binding<String>, identifier: String) -> some View {
        TextField("", text: text, prompt: Text(label))
            .textFieldStyle(.roundedBorder)
            .frame(width: SettingsLayout.idFieldWidth)
            .font(MailTheme.Typography.meta.font)
            .autocorrectionDisabled()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var tokenControl: some View {
        if model.hasToken && !model.isReplacingToken {
            HStack(spacing: MailTheme.Spacing.sm) {
                Label("Token saved", systemImage: "checkmark.circle.fill")
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ok)
                Button("Replace") { model.isReplacingToken = true }
                    .buttonStyle(SettingsOutlineButtonStyle())
                    .accessibilityLabel("Replace token")
                Button("Remove") { model.removeToken() }
                    .buttonStyle(SettingsOutlineButtonStyle(isDestructive: true))
                    .accessibilityLabel("Remove token")
                    .accessibilityIdentifier(AccessibilityID.Settings.aiGatewayRemoveToken)
            }
        } else {
            HStack(spacing: MailTheme.Spacing.sm) {
                SecureField("", text: $model.tokenDraft, prompt: Text("Paste token"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: SettingsLayout.tokenFieldWidth)
                    .onSubmit { model.saveToken() }
                    .accessibilityLabel("Gateway token")
                    .accessibilityIdentifier(AccessibilityID.Settings.aiGatewayToken)
                Button("Save") { model.saveToken() }
                    .buttonStyle(SettingsOutlineButtonStyle())
                    .disabled(model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save token")
                if model.isReplacingToken {
                    Button("Cancel") { model.cancelReplace() }
                        .buttonStyle(SettingsOutlineButtonStyle())
                }
            }
        }
        if let tokenError = model.tokenError {
            Text(tokenError)
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(MailTheme.Color.danger)
        }
    }
}

/// The page's state and behaviour, out of the view so it is testable with an
/// injected `UserDefaults` suite, secret store and URL session.
@MainActor
@Observable
final class AIGatewaySettingsModel {
    static let customSelection = "custom"

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let session: URLSession

    var accountID: String { didSet { AIGatewaySettings.setAccountID(accountID, in: defaults); testResult = nil } }
    var gatewayID: String { didSet { AIGatewaySettings.setGatewayID(gatewayID, in: defaults); testResult = nil } }
    var modelSelection: String { didSet { persistModel() } }
    var customModel: String { didSet { persistModel() } }

    /// Only ever the text being typed; cleared the moment it is saved.
    var tokenDraft = ""
    var isReplacingToken = false
    private(set) var hasToken: Bool
    private(set) var tokenError: String?
    private(set) var isTesting = false
    private(set) var testResult: TestResult?

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainStore(), session: URLSession = .shared) {
        self.defaults = defaults
        self.secrets = secrets
        self.session = session
        accountID = AIGatewaySettings.accountID(in: defaults)
        gatewayID = AIGatewaySettings.gatewayID(in: defaults)
        let stored = AIGatewaySettings.model(in: defaults)
        let isCurated = AIGatewaySettings.curatedModels.contains { $0.id == stored }
        modelSelection = isCurated ? stored : Self.customSelection
        customModel = isCurated ? "" : stored
        hasToken = AIGatewaySettings.hasToken(in: secrets)
    }

    var isCustomModelValid: Bool {
        AIGatewaySettings.isValidModelID(customModel.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var testResultText: String? {
        switch testResult {
        case .success: "Connected — the model answered."
        case .failure(let message): message
        case nil: nil
        }
    }

    func saveToken() {
        guard !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try AIGatewaySettings.saveToken(tokenDraft, in: secrets)
            tokenError = nil
            isReplacingToken = false
        } catch {
            tokenError = "Couldn't save the token to the Keychain."
        }
        tokenDraft = ""
        hasToken = AIGatewaySettings.hasToken(in: secrets)
        testResult = nil
    }

    func cancelReplace() {
        tokenDraft = ""
        isReplacingToken = false
    }

    func removeToken() {
        do {
            try AIGatewaySettings.removeToken(in: secrets)
            tokenError = nil
        } catch {
            tokenError = "Couldn't remove the token from the Keychain."
        }
        hasToken = AIGatewaySettings.hasToken(in: secrets)
        testResult = nil
    }

    func testConnection() async {
        guard let configuration = AIGatewaySettings.configuration(in: defaults) else {
            testResult = .failure(AIGatewaySettings.message(for: .invalidConfiguration))
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            try await AIGatewayClient(configuration: configuration, secrets: secrets, session: session).testConnection()
            testResult = .success
        } catch let error as AIGatewayError {
            testResult = .failure(AIGatewaySettings.message(for: error))
        } catch {
            testResult = .failure("The test failed unexpectedly.")
        }
    }

    private func persistModel() {
        testResult = nil
        if modelSelection == Self.customSelection {
            AIGatewaySettings.setModel(customModel, in: defaults)
        } else {
            AIGatewaySettings.setModel(modelSelection, in: defaults)
        }
    }
}
