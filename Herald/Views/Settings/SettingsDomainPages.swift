import HeraldKit
import SwiftUI

// A domain's own settings pages (handoff §3.2 "Domain pages"): Overview,
// Mailboxes, Signatures, and Remove domain (R9's Hide/Restore + the HQBase
// Admin link — no confirmation sheet, since nothing on it is destructive).
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
                            DomainBadge(
                                monogram: item.monogram,
                                tint: environment.domainTint(for: accountID, domainID: item.id), size: .sidebar
                            )
                            DomainMonogramField(
                                accountID: accountID,
                                item: item,
                                storedOverride: DomainPreferences.monogramOverride(
                                    accountID: accountID, domainID: item.id, in: environment.domainPreferencesObserved()
                                ) ?? ""
                            )
                        }
                    }
                    SettingsRow(
                        title: "Colour",
                        note: "Auto: the account’s colour.",
                        source: .herald
                    ) {
                        TintSwatchPicker(
                            current: environment.domainTint(for: accountID, domainID: item.id).name,
                            isOverridden: environment.domainTintOverride(for: accountID, domainID: item.id) != nil,
                            label: "Domain colour",
                            resetHelp: "Go back to the account’s colour",
                            swatchIDPrefix: AccessibilityID.Settings.domainTintSwatchPrefix,
                            resetID: AccessibilityID.Settings.domainTintReset,
                            pick: { name in
                                Task { await environment.setDomainTint(name, for: accountID, domainID: item.id) }
                            }
                        )
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
        // `item.monogram`, not `DomainMonogram.derive(from:)` (audit F3 #7):
        // the badge right beside this field already draws the LIVE monogram
        // (2 letters, or 3 when clash-promoted against another of the
        // account's domains) — the placeholder must show the same letters
        // "Auto" would actually assign, not a bare re-derivation that ignores
        // clashes and so can silently disagree with the badge next to it.
        TextField("", text: $draft, prompt: Text(item.monogram))
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
        // The decision itself lives in `DomainMonogram.wouldCommitOverride`
        // (audit F3 #11) — pure and testable there, not re-implemented here.
        guard DomainMonogram.wouldCommitOverride(raw) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        write { DomainPreferences.setMonogramOverride(trimmed.isEmpty ? nil : trimmed, accountID: accountID, domainID: item.id, in: $0) }
    }

    // `reloads: false` (audit F3 #9): the monogram is a repaint-only
    // preference — it changes no list, count or badge — so every valid
    // keystroke no longer pays for a `reloadConversations` + `reloadDrafts`.
    private func write(_ apply: @escaping (UserDefaults) -> Void) {
        Task { await environment.updateDomainPreferences(accountID: accountID, reloads: false, apply) }
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

    // The 11pt "On" word drawn in `ok` (green) on `surface` measured 4.39:1 —
    // under AA's 4.5:1 for text that size (audit F3 #5). The colour cue now
    // lives on the glyph only (still paired with the word, per the design
    // system's every-colour-cue-has-text-or-shape rule); the word itself
    // draws in `ink2`, same as the "Off" state, which already passed.
    private func status(_ on: Bool, onLabel: String, offLabel: String) -> some View {
        HStack(spacing: MailTheme.Spacing.xxs) {
            Image(systemName: on ? MailTheme.Symbol.receiveSendOn : MailTheme.Symbol.receiveSendOff)
                .foregroundStyle(on ? MailTheme.Color.ok : MailTheme.Color.ink3)
            Text(on ? "On" : "Off")
                .textStyle(MailTheme.Typography.caption)
                .foregroundStyle(MailTheme.Color.ink2)
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
                Label(actionError, systemImage: MailTheme.Symbol.warning)
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
                // Gated on THIS domain's own scope (audit F3 #6), not just
                // `scopeOptions.isEmpty` — that stayed enabled whenever ANY
                // scope was offered, even one belonging to a different
                // domain, and `beginCreate(preferring:)` used to silently
                // substitute it in. A domain whose mailboxes have not
                // finished loading a signature-manageable one yet disables
                // the button instead, with a reason.
                let domainScope = SignatureScopeRef(type: .domain, id: domainID)
                let scopeAvailable = model.offersScope(domainScope)
                Button {
                    model.beginCreate(preferring: domainScope)
                } label: {
                    Label("New Signature", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scopeAvailable)
                .accessibilityIdentifier(AccessibilityID.Settings.domainNewSignature)
                .help(
                    scopeAvailable
                        ? "New signature for \(domainName)."
                        : "This domain has no signature-manageable mailbox loaded yet."
                )
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
                        .frame(width: MailTheme.iconButtonSize.width, height: MailTheme.iconButtonSize.height)
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

// MARK: - Remove domain

/// Settings › {domain} › Remove domain (handoff §3.2 "Remove domain"): Hide
/// Domain (never a server delete — Herald has no domain-delete API and asks
/// for no confirmation, since nothing on this page is destructive), the
/// account's Hidden Domains list with Restore, and a neutral card pointing at
/// where a workspace admin actually deletes a domain.
struct DomainRemoveSettingsPage: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem
    let accountID: Account.ID
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: DomainSettingsPage.remove.title, breadcrumb: breadcrumb) {
            SettingsCard {
                actionRow(
                    title: "Hide from Herald",
                    source: .herald,
                    note: "Removes \(item.domain.name) from the sidebar, unread counts and notifications "
                        + "on this Mac. Nothing changes on the server. You can restore it below."
                ) {
                    Button("Hide Domain") {
                        Task { await environment.hideDomain(item.id, accountID: accountID) }
                    }
                    .buttonStyle(SettingsOutlineButtonStyle())
                    .accessibilityLabel("Hide \(item.domain.name) from Herald")
                    .accessibilityIdentifier(AccessibilityID.Settings.hideDomain)
                }
            }
            HiddenDomainsSection(
                items: environment.hiddenDomains(accountID: accountID),
                accountID: accountID,
                tint: environment.accountTint(for: accountID)
            )
            if let account = environment.graphs[accountID]?.account {
                SettingsCard(fill: MailTheme.Color.bg) {
                    actionRow(
                        title: "Delete this domain on the server",
                        source: .server,
                        note: "Deleting a domain and its mailboxes is managed by a workspace admin in HQBase. "
                            + "Herald can’t delete domains."
                    ) {
                        // `nil` only for an origin the sign-in flow should
                        // already have refused (non-https) — disabled rather
                        // than a silent no-op if that guard is ever wrong.
                        let adminURL = AppEnvironment.hqBaseAdminURL(for: account)
                        Button {
                            environment.openHQBaseAdmin(for: account)
                        } label: {
                            // The arrow trails the title ("Open in HQBase Admin ↗",
                            // handoff §3.2 / 4a-4) — an outbound-link cue, not a
                            // leading icon.
                            HStack(spacing: MailTheme.Spacing.xs) {
                                Text("Open in HQBase Admin")
                                Image(systemName: MailTheme.Symbol.openAdmin)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(SettingsOutlineButtonStyle())
                        .disabled(adminURL == nil)
                        .accessibilityLabel("Open HQBase Admin in your browser")
                        .accessibilityIdentifier(AccessibilityID.Settings.openAdmin)
                        .help(
                            adminURL == nil
                                ? "This account's server address can't be opened as a link."
                                : "Opens \(adminURL!.absoluteString) in your browser."
                        )
                    }
                }
            }
        }
    }

    /// The shared shape of this page's two cards: a title (tagged SERVER/
    /// HERALD) and an explanation on the left, one action on the right — the
    /// same layout `SettingsRow` draws, but full-bleed (no `maxWidth`-clamped
    /// control column) since each of these rows is the card's only content.
    private func actionRow<Trailing: View>(
        title: String,
        source: SettingsSource,
        note: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: MailTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                HStack(spacing: MailTheme.Spacing.sm) {
                    Text(title)
                        .textStyle(MailTheme.Typography.bodyMedium)
                        .foregroundStyle(MailTheme.Color.ink)
                    SettingsSourceTag(source: source)
                }
                Text(note)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, MailTheme.Spacing.lg)
        .padding(.horizontal, MailTheme.Spacing.lg)
    }
}

/// "HIDDEN DOMAINS" (handoff §3.2): every domain this account has hidden, with
/// Restore. Shown on the Remove-domain page (as designed) AND, so a user can
/// always get back a domain even when EVERY domain is hidden — at which point
/// `settingsDomains(accountID:)` is empty, the sidebar's Domains section
/// disappears, and no domain's Remove-domain page is reachable at all — again
/// at the bottom of Settings › Account (``AccountSettingsPage``). Reusable
/// rather than forked so the two spots can never disagree on what "hidden"
/// means.
struct HiddenDomainsSection: View {
    @Environment(AppEnvironment.self) private var environment
    /// Computed ONCE by the caller (audit F3 #9), not re-derived here: this
    /// reads `UserDefaults.dictionaryRepresentation()` in full
    /// (``DomainPreferences/hiddenDomainIDs(accountID:in:)``), and
    /// `AccountSettingsPage` already needs the same list for its own
    /// `isEmpty` gate — computing it again in this view's own `body` doubled
    /// that scan every render for no reason.
    let items: [HiddenDomainItem]
    let accountID: Account.ID
    let tint: MailTheme.AccountTint

    var body: some View {
        SettingsSection(title: "Hidden domains") {
            SettingsCard {
                if items.isEmpty {
                    Text("No hidden domains.")
                        .textStyle(MailTheme.Typography.caption)
                        .foregroundStyle(MailTheme.Color.ink3)
                        // Full width: without it the card hugs the sentence
                        // instead of spanning the column like every other card.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, MailTheme.Spacing.md)
                        .padding(.horizontal, MailTheme.Spacing.lg)
                } else {
                    ForEach(items) { item in
                        HiddenDomainRow(
                            item: item,
                            tint: DomainBadgeResolver.tint(
                                domainID: item.id, accountID: accountID, accountTint: tint,
                                in: environment.domainPreferencesObserved()
                            )
                        ) {
                            Task { await environment.restoreDomain(item.id, accountID: accountID) }
                        }
                    }
                }
            }
        }
    }
}

/// One hidden domain: its badge at 60% opacity, name, "Hidden {date} · N
/// mailboxes", and Restore.
private struct HiddenDomainRow: View {
    let item: HiddenDomainItem
    let tint: MailTheme.AccountTint
    let restore: () -> Void

    var body: some View {
        HStack(spacing: MailTheme.Spacing.md) {
            DomainBadge(monogram: item.monogram, tint: tint, size: .sidebar)
                .opacity(MailTheme.Wash.hiddenBadgeOpacity)
            VStack(alignment: .leading, spacing: MailTheme.Spacing.xxs) {
                Text(item.name)
                    .textStyle(MailTheme.Typography.body)
                    .foregroundStyle(MailTheme.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(note)
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore", action: restore)
                .buttonStyle(SettingsOutlineButtonStyle())
                .accessibilityLabel("Restore \(item.name)")
                .accessibilityIdentifier(AccessibilityID.Settings.restoreDomainPrefix + item.id)
        }
        .padding(.vertical, MailTheme.Spacing.sm + MailTheme.Spacing.xxs)
        .padding(.horizontal, MailTheme.Spacing.lg)
    }

    private var note: String {
        let mailboxes = item.allMailboxesDisabled
            ? "Disabled on the server"
            : (item.mailboxCount == 1 ? "1 mailbox" : "\(item.mailboxCount) mailboxes")
        guard let hiddenAt = item.hiddenAt else { return mailboxes }
        return "Hidden \(Self.dateFormatter.string(from: hiddenAt)) · \(mailboxes)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
