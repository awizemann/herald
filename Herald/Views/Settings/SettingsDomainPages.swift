import HeraldKit
import SwiftUI

// A domain's own settings pages (handoff §3.2 "Domain pages"): Overview,
// Mailboxes, Signatures. Remove domain stays a placeholder — R9 builds it.
// Chrome in `SettingsChrome.swift`; routing in `SettingsView.swift`.

// MARK: - Overview

/// Settings › {domain} › Overview: the server facts (name, mailbox count) plus
/// the Herald-only monogram override and the three "on this Mac" toggles.
struct DomainOverviewSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem
    let accountID: Account.ID
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: DomainSettingsPage.overview.title, breadcrumb: breadcrumb) {
            SettingsSection(title: "Domain") {
                SettingsCard {
                    SettingsRow(title: "Name", source: .server) {
                        Text(item.domain.name)
                            .textStyle(MailTheme.Typography.meta)
                            .foregroundStyle(MailTheme.Color.ink2)
                            .textSelection(.enabled)
                    }
                    SettingsRow(title: "Mailboxes you can access", source: .server) {
                        Text(String(item.domain.mailboxIDs.count))
                            .textStyle(MailTheme.Typography.meta)
                            .foregroundStyle(MailTheme.Color.ink2)
                    }
                    SettingsRow(
                        title: "Monogram",
                        note: "Two or three letters. Auto: first letters of the domain.",
                        source: .herald
                    ) {
                        HStack(spacing: MailTheme.Spacing.sm) {
                            DomainBadge(monogram: item.monogram, tint: environment.accountTint(for: accountID), size: .sidebar)
                            DomainMonogramField(
                                accountID: accountID,
                                item: item,
                                storedOverride: DomainPreferences.monogramOverride(
                                    accountID: accountID, domainID: item.id, in: environment.domainPreferencesObserved()
                                ) ?? ""
                            )
                        }
                    }
                }
            }
            SettingsSection(title: "On this Mac") {
                SettingsCard {
                    SettingsRow(
                        title: "Include in “All domains”",
                        note: "Its mail appears in the combined list and in the account’s unread total.",
                        source: .herald
                    ) {
                        Toggle("Include in All domains", isOn: includeInAllBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Settings.domainIncludeInAll)
                    }
                    SettingsRow(
                        title: "Count unread in the Dock badge",
                        note: "Leave off for noisy domains, such as billing or notifications.",
                        source: .herald
                    ) {
                        Toggle("Count unread in the Dock badge", isOn: countInBadgeBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Settings.domainCountInBadge)
                    }
                    DomainNotifyRow(accountID: accountID, domainID: item.id)
                }
            }
        }
    }

    private var includeInAllBinding: Binding<Bool> {
        Binding(
            get: { DomainPreferences.includeInAll(accountID: accountID, domainID: item.id, in: environment.domainPreferencesObserved()) },
            set: { newValue in
                Task {
                    await environment.updateDomainPreferences(accountID: accountID) { defaults in
                        DomainPreferences.setIncludeInAll(newValue, accountID: accountID, domainID: item.id, in: defaults)
                    }
                }
            }
        )
    }

    private var countInBadgeBinding: Binding<Bool> {
        Binding(
            get: { DomainPreferences.countInBadge(accountID: accountID, domainID: item.id, in: environment.domainPreferencesObserved()) },
            set: { newValue in
                Task {
                    await environment.updateDomainPreferences(accountID: accountID) { defaults in
                        DomainPreferences.setCountInBadge(newValue, accountID: accountID, domainID: item.id, in: defaults)
                    }
                }
            }
        )
    }
}

/// The monogram override field: an empty field means "auto" (the placeholder
/// shows what that auto value is); typing 2–3 letters writes an override,
/// clearing the field removes it. Only a value that VALIDATES (or emptying the
/// field) writes through ``AppEnvironment/updateDomainPreferences(accountID:_:)``
/// — an in-progress invalid keystroke is left alone rather than clearing a
/// stored override out from under the user (``DomainMonogram/normalizeOverride(_:)``
/// is the same check the storage layer applies, so nothing invalid can reach
/// `UserDefaults` from here either way).
private struct DomainMonogramField: View {
    @Environment(AppEnvironment.self) private var environment
    let accountID: Account.ID
    let item: SettingsDomainItem
    @State private var draft: String

    /// `storedOverride` is read by the PARENT (where `@Environment` is
    /// available) and handed in as the field's initial value — the field's own
    /// stored override, not the resolved `item.monogram` (which is auto-derived
    /// when there is none). `SettingsDetail`'s `.id(domainID)` gives this field
    /// a fresh `@State` per domain, so this initial read is never stale.
    init(accountID: Account.ID, item: SettingsDomainItem, storedOverride: String) {
        self.accountID = accountID
        self.item = item
        _draft = State(initialValue: storedOverride)
    }

    var body: some View {
        TextField("", text: $draft, prompt: Text(DomainMonogram.derive(from: item.domain.name)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .multilineTextAlignment(.center)
            .font(MailTheme.Typography.meta.font)
            .onChange(of: draft) { _, newValue in commit(newValue) }
            .accessibilityLabel("Monogram override")
            .accessibilityValue(draft.isEmpty ? "Automatic" : draft)
            .accessibilityIdentifier(AccessibilityID.Settings.domainMonogram)
    }

    private func commit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            write { DomainPreferences.setMonogramOverride(nil, accountID: accountID, domainID: item.id, in: $0) }
            return
        }
        guard DomainMonogram.normalizeOverride(trimmed) != nil else { return }
        write { DomainPreferences.setMonogramOverride(trimmed, accountID: accountID, domainID: item.id, in: $0) }
    }

    private func write(_ apply: @escaping (UserDefaults) -> Void) {
        Task { await environment.updateDomainPreferences(accountID: accountID, apply) }
    }
}

/// "Notify me about new mail": shows the EFFECTIVE value (``DomainNotifyEffective``)
/// and, while the global switch is off, disables the control and explains why
/// with a link back to Settings › Notifications — the domain switch cannot
/// override a global OFF (see ``MailViewModel/notificationSilencedMailboxIDs()``).
private struct DomainNotifyRow: View {
    @Environment(AppEnvironment.self) private var environment
    let accountID: Account.ID
    let domainID: MailDomain.ID
    // `@AppStorage`, not a raw `defaults` read: the global switch lives on a
    // DIFFERENT page (Settings › Notifications) and is written through its own
    // `@AppStorage`, which is the one mechanism that notifies a view that did
    // not make the write. A raw read through `domainPreferencesObserved()`
    // would only repaint on a `DomainPreferences` write, never this one.
    @AppStorage(NotificationSettings.newMailKey) private var globalEnabled = true

    var body: some View {
        let defaults = environment.domainPreferencesObserved()
        let explicit = DomainPreferences.notify(accountID: accountID, domainID: domainID, in: defaults)
        let effective = DomainNotifyEffective.effective(explicit: explicit, globalEnabled: globalEnabled)

        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
            HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                    Text("Notify me about new mail")
                        .textStyle(MailTheme.Typography.body)
                        .foregroundStyle(MailTheme.Color.ink)
                    Text("Per domain. Uses the global notification setting as its default.")
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Notify me about new mail", isOn: Binding(
                    get: { effective },
                    set: { newValue in
                        Task {
                            await environment.updateDomainPreferences(accountID: accountID) { defaults in
                                DomainPreferences.setNotify(newValue, accountID: accountID, domainID: domainID, in: defaults)
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!globalEnabled)
                .accessibilityIdentifier(AccessibilityID.Settings.domainNotify)
                .accessibilityHint(globalEnabled ? "" : "Notifications are off for every account in Settings, Notifications")
                SettingsSourceTag(source: .herald)
            }
            if !globalEnabled {
                Button("Notifications are off in Settings › Notifications") {
                    environment.settingsRoute = .notifications
                }
                .buttonStyle(.plain)
                .foregroundStyle(MailTheme.Color.accent)
                .textStyle(MailTheme.Typography.caption)
            }
        }
        .padding(.vertical, MailTheme.Spacing.md)
        .padding(.horizontal, MailTheme.Spacing.lg)
    }
}

// MARK: - Mailboxes

/// Settings › {domain} › Mailboxes: a read-only table of the domain's
/// addresses, sourced from the account's cached mailboxes (`GET /mailboxes`)
/// and filtered to this domain's membership — never a fetch of its own.
struct DomainMailboxesSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem
    let accountID: Account.ID
    let breadcrumb: String

    var body: some View {
        let rows = Self.rows(mailboxes: environment.graphs[accountID]?.mail.mailboxes ?? [], domain: item.domain)
        SettingsPage(title: DomainSettingsPage.mailboxes.title, breadcrumb: breadcrumb) {
            Text(
                "Addresses on \(item.domain.name) you can access. Sender name, receive and send settings "
                    + "are managed on the server, so they’re read-only here."
            )
            .textStyle(MailTheme.Typography.caption)
            .foregroundStyle(MailTheme.Color.ink2)
            .fixedSize(horizontal: false, vertical: true)
            DomainMailboxTable(rows: rows)
                .accessibilityIdentifier(AccessibilityID.Settings.domainMailboxTable)
        }
    }

    /// Pure: one row per mailbox in the domain, in `MailDomain`'s deterministic
    /// order (alphabetical by local part), each carrying its primary address's
    /// server-reported fields. A mailbox id the account no longer has loaded
    /// (a race with sync) is skipped rather than shown with blank fields.
    static func rows(mailboxes: [Mailbox], domain: MailDomain) -> [DomainMailboxRow.Data] {
        let byID = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.id, $0) })
        return domain.mailboxIDs.compactMap { id -> DomainMailboxRow.Data? in
            guard let mailbox = byID[id], let address = mailbox.addresses.first else { return nil }
            let localPart = address.address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address.address
            return DomainMailboxRow.Data(
                id: mailbox.id,
                localPart: localPart,
                domainName: domain.name,
                isPrimary: address.isPrimary,
                senderName: mailbox.displayName,
                canReceive: address.receiveEnabled,
                canSend: address.sendEnabled
            )
        }
    }
}

/// The table's card frame: a header row over a `LazyVStack` of data rows, so an
/// account with up to 100 mailboxes on one domain never eagerly lays out rows
/// off screen (unlike ``SettingsCard``, built for a handful of fixed rows).
private struct DomainMailboxTable: View {
    let rows: [DomainMailboxRow.Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hairline
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    DomainMailboxRow(data: row)
                    if index < rows.count - 1 { hairline }
                }
            }
        }
        .background(MailTheme.Color.surface, in: RoundedRectangle(cornerRadius: MailTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: MailTheme.Radius.lg)
                .strokeBorder(MailTheme.Color.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: MailTheme.Spacing.md) {
            Text("Address").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sender name").frame(width: 160, alignment: .leading)
            Text("Receive").frame(width: 64, alignment: .leading)
            Text("Send").frame(width: 64, alignment: .leading)
        }
        .textStyle(MailTheme.Typography.caption)
        .foregroundStyle(MailTheme.Color.ink3)
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.sm)
        .accessibilityHidden(true)
    }

    private var hairline: some View {
        Rectangle()
            .fill(MailTheme.Color.lineSoft)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// One mailbox: its address (with a "Primary" pill), sender name, and the
/// receive/send status icons — each independently labelled for VoiceOver, and
/// combined into one element per row so a screen-reader user swipes once per
/// mailbox rather than four times.
struct DomainMailboxRow: View {
    struct Data: Sendable, Hashable, Identifiable {
        let id: String
        let localPart: String
        let domainName: String
        let isPrimary: Bool
        let senderName: String
        let canReceive: Bool
        let canSend: Bool
    }

    let data: Data

    var body: some View {
        HStack(spacing: MailTheme.Spacing.md) {
            HStack(spacing: MailTheme.Spacing.xs) {
                Text("\(data.localPart)@")
                    .textStyle(MailTheme.Typography.bodyMedium)
                    .foregroundStyle(MailTheme.Color.ink)
                Text(data.domainName)
                    .textStyle(MailTheme.Typography.body)
                    .foregroundStyle(MailTheme.Color.ink3)
                if data.isPrimary { primaryPill }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(data.senderName)
                .textStyle(MailTheme.Typography.body)
                .foregroundStyle(MailTheme.Color.ink2)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
            status(data.canReceive, onLabel: "Receive on", offLabel: "Receive off")
                .frame(width: 64, alignment: .leading)
            status(data.canSend, onLabel: "Send on", offLabel: "Send off")
                .frame(width: 64, alignment: .leading)
        }
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.vertical, MailTheme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private var primaryPill: some View {
        Text("Primary")
            .textStyle(MailTheme.Typography.caption)
            .foregroundStyle(MailTheme.Color.ink3)
            .padding(.horizontal, MailTheme.Spacing.sm)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(MailTheme.Color.lineSoft, in: Capsule())
    }

    private func status(_ on: Bool, onLabel: String, offLabel: String) -> some View {
        HStack(spacing: MailTheme.Spacing.xxs) {
            Image(systemName: on ? "checkmark.circle.fill" : "nosign")
                .foregroundStyle(on ? MailTheme.Color.ok : MailTheme.Color.ink3)
            Text(on ? "On" : "Off")
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(on ? MailTheme.Color.ok : MailTheme.Color.ink3)
        }
        .accessibilityLabel(on ? onLabel : offLabel)
    }
}

// MARK: - Signatures

/// Settings › {domain} › Signatures: this domain's slice of the existing
/// cross-scope signature list (``SignatureSettingsModel``), with its own "New
/// Signature" pre-scoped to the domain. Reuses the model's load/edit/delete
/// logic and the shared editor sheet (``View/signatureManagementModifiers(model:)``)
/// rather than forking them — a mutation here updates the SAME list Settings ›
/// Signatures and the sidebar's domain count read.
struct DomainSignaturesSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem
    let accountID: Account.ID
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: DomainSettingsPage.signatures.title, breadcrumb: breadcrumb) {
            if let model = environment.signatureSettingsModel() {
                DomainSignatureList(
                    model: model,
                    domainID: item.id,
                    domainName: item.domain.name,
                    reauthenticate: { environment.reauthenticateSelectedAccount() }
                )
            }
        }
    }
}

private struct DomainSignatureList: View {
    let model: SignatureSettingsModel
    let domainID: MailDomain.ID
    let domainName: String
    let reauthenticate: () -> Void

    var body: some View {
        Group {
            if model.state == .ready {
                readyContent
            } else {
                // Loading, and every way loading can fail (a server too old,
                // an account that needs to sign in again, …) are identical to
                // the root Signatures page's — reused, not forked.
                SignatureStateMessagePane(model: model, reauthenticate: reauthenticate)
            }
        }
        // Keyed on the model's identity, like the root Signatures page: a new
        // account hands this page a different model, whose load has to re-run.
        .task(id: ObjectIdentifier(model)) { await model.load() }
        .signatureManagementModifiers(model: model)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.md) {
            if let actionError = model.actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(MailTheme.failure)
                    .textStyle(MailTheme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: MailTheme.Spacing.lg) {
                Text(
                    "Domain signatures apply to every address on \(domainName). "
                        + "A mailbox's own default wins, then yours, then the domain's."
                )
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(MailTheme.Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.beginCreate(preferring: SignatureScopeRef(type: .domain, id: domainID))
                } label: {
                    Label("New Signature", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.scopeOptions.isEmpty)
                .accessibilityIdentifier(AccessibilityID.Settings.domainNewSignature)
            }
            if signatures.isEmpty {
                Text("No signatures for this domain yet.")
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
            } else {
                SettingsCard {
                    ForEach(signatures) { signature in
                        DomainSignatureRow(model: model, signature: signature)
                    }
                }
            }
            Text("Only domain admins can manage these. Others see them read-only, with the reason the server gives.")
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(MailTheme.Color.ink3)
        }
    }

    /// This domain's slice of the shared list — never a fetch of its own.
    private var signatures: [Signature] {
        model.groups.first { $0.scope == .domain && $0.scopeID == domainID }?.signatures ?? []
    }
}

/// One domain signature: name, a "Default" pill, a one-line preview, Edit and a
/// more menu (Delete) — the same actions the root Signatures list offers,
/// dressed in the Settings card chrome instead of a `Form` row.
private struct DomainSignatureRow: View {
    let model: SignatureSettingsModel
    let signature: Signature

    var body: some View {
        HStack(alignment: .top, spacing: MailTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                HStack(spacing: MailTheme.Spacing.sm) {
                    Text(signature.name)
                        .textStyle(MailTheme.Typography.bodyMedium)
                        .foregroundStyle(MailTheme.Color.ink)
                        .lineLimit(1)
                    if signature.isDefault { defaultPill }
                }
                if !preview.isEmpty {
                    Text(preview)
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: MailTheme.Spacing.sm) {
                Button("Edit") { model.beginEdit(signature) }
                    .buttonStyle(SettingsOutlineButtonStyle())
                Menu {
                    Button("Delete", role: .destructive) { model.pendingDeletion = signature }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: MailTheme.hitTarget, height: MailTheme.hitTarget)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("More actions for \(signature.name)")
            }
        }
        .padding(.vertical, MailTheme.Spacing.md)
        .padding(.horizontal, MailTheme.Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(signature.isDefault ? "\(signature.name), default" : signature.name)
    }

    /// The server's plain-text rendering, first line only.
    private var preview: String {
        signature.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private var defaultPill: some View {
        Text("Default")
            .textStyle(MailTheme.Typography.caption)
            .padding(.horizontal, MailTheme.Spacing.sm)
            .padding(.vertical, MailTheme.Spacing.xxs)
            .background(MailTheme.chipBackground, in: Capsule())
            .foregroundStyle(MailTheme.chipLabelForeground)
            .accessibilityHidden(true)
    }
}

// MARK: - Remove domain (placeholder — R9)

/// A domain page before its real content exists.
///
/// PLACEHOLDER: phase R9 builds Remove domain. It replaces its `case` in
/// `SettingsDetail.domainPage(_:item:accountID:breadcrumb:)` with its own page,
/// built from the same chrome (`SettingsPage`, `SettingsSection`,
/// `SettingsCard`, `SettingsRow`, `SettingsSourceTag`) — then this type goes.
struct DomainSettingsPlaceholderPage: View {
    let item: SettingsDomainItem
    let page: DomainSettingsPage
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: page.title, breadcrumb: breadcrumb) {
            SettingsCard {
                SettingsRow(
                    title: "Not built yet",
                    note: "This page for \(item.domain.name) is built in phase R9."
                )
            }
        }
    }
}
