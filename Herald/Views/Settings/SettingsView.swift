import HeraldKit
import SwiftUI

/// ⌘, — the Settings window: a drill-down source list on the left, the page on
/// the right (handoff §3.2). The layout is the template for every settings area
/// that follows (domain pages, Workflows later).
///
/// A `NavigationSplitView` with a fixed-width sidebar, inside the `Settings`
/// scene: it is what gives the window the full-height sidebar material under a
/// transparent title bar (the System Settings look). The sidebar toggle is
/// removed and the column width pinned — this window never collapses its
/// sidebar. The page shown is ``AppEnvironment/settingsRoute`` (resolved against
/// the selected account), so a deep link sets the route and opens the window.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(SettingsLayout.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(route: environment.resolvedSettingsRoute)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(
            minWidth: SettingsLayout.minSize.width, idealWidth: SettingsLayout.defaultSize.width,
            minHeight: SettingsLayout.minSize.height, idealHeight: SettingsLayout.defaultSize.height
        )
    }
}

// MARK: - Sidebar

/// The account card, then either the root sections or one domain's pages.
///
/// ONE `List` whose rows switch with the level, so there is one selection and
/// one source-list view for both levels; the level's chrome ("‹ Settings" and
/// the domain header above, Remove domain pinned below) rides in safe-area
/// insets, outside the selectable rows.
private struct SettingsSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let route = environment.resolvedSettingsRoute
        let accountID = environment.selectedAccountID
        let domains = accountID.map { environment.settingsDomains(accountID: $0) } ?? []
        let openDomain = route.domainID.flatMap { id in domains.first { $0.id == id } }
        List(selection: selection) {
            if let openDomain {
                SettingsDomainRows(item: openDomain)
            } else {
                SettingsRootRows(domains: domains, accountID: accountID)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.Settings.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsAccountCard()
                Rectangle()
                    .fill(MailTheme.Color.lineSoft)
                    .frame(height: 1)
                    .padding(.horizontal, MailTheme.Spacing.md)
                    .accessibilityHidden(true)
                if let openDomain, let accountID {
                    SettingsDomainHeader(item: openDomain, tint: environment.accountTint(for: accountID), back: back)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let openDomain {
                SettingsRemoveDomainRow(item: openDomain, selection: selection)
            }
        }
    }

    /// Reads the RESOLVED route, so the highlighted row is the page on screen.
    /// A write is a user's pick; entering or leaving a domain is a level
    /// change, animated with the scope token unless Reduce Motion is on.
    ///
    /// Rows are tagged `.tag(route)` — never `.tag(Optional(route))`. Since
    /// macOS 15 `tag(_:includeOptional:)` already matches an Optional
    /// selection, and an explicitly wrapped tag matched nothing: the spike's
    /// rows ignored clicks and drew no highlight.
    private var selection: Binding<SettingsRoute?> {
        Binding(
            get: { environment.resolvedSettingsRoute },
            set: { newValue in
                guard let newValue, newValue != environment.resolvedSettingsRoute else { return }
                let changesLevel = newValue.domainID != environment.settingsRoute.domainID
                withAnimation(changesLevel && !reduceMotion ? MailTheme.Animation.scope : nil) {
                    environment.settingsRoute = newValue
                }
            }
        )
    }

    private func back() {
        withAnimation(reduceMotion ? nil : MailTheme.Animation.scope) {
            environment.settingsRoute = .general
        }
    }
}

/// HERALD · ACCOUNT · DOMAINS. A domain row drills in (to its Overview).
private struct SettingsRootRows: View {
    @Environment(AppEnvironment.self) private var environment
    let domains: [SettingsDomainItem]
    let accountID: Account.ID?

    var body: some View {
        ForEach(groups, id: \.title) { group in
            Section {
                ForEach(group.routes, id: \.self) { route in
                    Label(route.title, systemImage: route.symbol)
                        .tag(route)
                        .accessibilityIdentifier(AccessibilityID.Settings.itemPrefix + route.accessibilityKey)
                }
            } header: {
                SettingsSidebarHeader(title: group.title)
            }
        }
        if !domains.isEmpty, let accountID {
            Section {
                ForEach(domains) { item in
                    Label {
                        Text(item.domain.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        SettingsDomainBadge(monogram: item.monogram, tint: environment.accountTint(for: accountID))
                    }
                    .badge(Text(Image(systemName: "chevron.right")))
                    .tag(SettingsRoute.domain(item.id, .overview))
                    // The name only — not the badge letters or the chevron.
                    .accessibilityLabel(item.domain.name)
                    .accessibilityHint("Opens this domain's settings")
                    .accessibilityIdentifier(AccessibilityID.Settings.itemPrefix + "domain.\(item.id)")
                }
            } header: {
                SettingsSidebarHeader(title: "Domains")
            }
        }
    }

    /// No account, no ACCOUNT section: its pages would resolve to General
    /// anyway, and a section of dead rows is worse than none.
    private var groups: [(title: String, routes: [SettingsRoute])] {
        SettingsRoute.rootGroups.filter { group in
            environment.selectedGraph != nil || !group.routes.contains(.account)
        }
    }
}

/// "HERALD", "ACCOUNT", "DOMAINS" — the handoff's uppercase section caption,
/// not the source list's default title-case header.
private struct SettingsSidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .textStyle(MailTheme.Typography.section)
            .foregroundStyle(MailTheme.Color.ink3)
    }
}

/// One domain's pages. Remove domain is not here: it is pinned to the bottom
/// (``SettingsRemoveDomainRow``).
private struct SettingsDomainRows: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SettingsDomainItem

    var body: some View {
        Section {
            page(.overview, meta: nil)
            page(.mailboxes, meta: String(item.domain.mailboxIDs.count))
            page(.signatures, meta: signatureCount.map(String.init))
            // Not built yet: shown so the layout reads as designed, never
            // selectable (no tag), and it says why in words, not only by being
            // dimmed.
            Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
                .badge(Text("LATER").font(MailTheme.Typography.tag.font))
                .opacity(0.5)
                .accessibilityLabel("Workflows, coming later")
        }
    }

    private func page(_ page: DomainSettingsPage, meta: String?) -> some View {
        let route = SettingsRoute.domain(item.id, page)
        return Label(page.title, systemImage: page.symbol)
            .badge(meta.map { Text($0).font(MailTheme.Typography.meta.font) })
            .tag(route)
            .accessibilityIdentifier(AccessibilityID.Settings.itemPrefix + route.accessibilityKey)
    }

    /// The domain's signature count, once Settings › Signatures has loaded the
    /// list — never a fetch of its own from the sidebar (R8 owns that page).
    private var signatureCount: Int? {
        guard let model = environment.signatureSettingsModel(), model.state == .ready else { return nil }
        return model.groups.first { $0.scope == .domain && $0.scopeID == item.id }?.signatures.count ?? 0
    }
}

/// "Remove domain", pinned below the domain's pages: its own one-row list on
/// the same selection, so it keeps the native source-list highlight.
private struct SettingsRemoveDomainRow: View {
    let item: SettingsDomainItem
    let selection: Binding<SettingsRoute?>

    var body: some View {
        let route = SettingsRoute.domain(item.id, .remove)
        // Shows the shared selection only when it is THIS row, and never writes
        // a deselection back: this one-row list has no row for any other page,
        // and a nil from it must not clear the main list's selection.
        List(selection: Binding(
            get: { selection.wrappedValue == route ? route : nil },
            set: { if let newValue = $0 { selection.wrappedValue = newValue } }
        )) {
            Label(DomainSettingsPage.remove.title, systemImage: DomainSettingsPage.remove.symbol)
                .tag(route)
                .accessibilityIdentifier(AccessibilityID.Settings.itemPrefix + route.accessibilityKey)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .frame(height: SettingsLayout.rowHeight + MailTheme.Spacing.lg)
    }
}

/// "‹ Settings" and the domain's badge + name, above its pages. Outside the
/// list: neither is a page, so neither belongs among the selectable rows.
private struct SettingsDomainHeader: View {
    let item: SettingsDomainItem
    let tint: MailTheme.AccountTint
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MailTheme.Spacing.xs) {
            Button(action: back) {
                Label("Settings", systemImage: "chevron.left")
                    .foregroundStyle(MailTheme.Color.ink2)
                    .frame(minHeight: MailTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to all settings")
            .accessibilityLabel("Back to Settings")
            .accessibilityIdentifier(AccessibilityID.Settings.back)

            HStack(spacing: MailTheme.Spacing.sm) {
                SettingsDomainBadge(monogram: item.monogram, tint: tint, size: SettingsLayout.headerBadgeSize)
                Text(item.domain.name)
                    .textStyle(MailTheme.Typography.headline)
                    .foregroundStyle(MailTheme.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MailTheme.Spacing.lg)
        .padding(.top, MailTheme.Spacing.sm)
    }
}

/// Avatar, account name, server host; its menu switches the account, like the
/// main window's switcher (the two share one selection).
private struct SettingsAccountCard: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let account = environment.selectedGraph?.account {
            Group {
                if environment.accountIDs.count > 1 {
                    Menu {
                        Picker("Account", selection: pickedAccountID) {
                            ForEach(environment.accounts) { other in
                                Text(AppEnvironment.accountPickerLabel(for: other, unread: 0)).tag(other.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        card(for: account, switchable: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("Switch account")
                    .accessibilityLabel("Account: \(account.label), \(Self.caption(for: account))")
                    .accessibilityHint("Switches which account these settings are for")
                } else {
                    // One account: nothing to switch to. A plain card, not a
                    // disabled menu — disabling dims the whole card.
                    card(for: account, switchable: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Account: \(account.label), \(Self.caption(for: account))")
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.accountCard)
            .padding(.horizontal, MailTheme.Spacing.md)
            .padding(.vertical, MailTheme.Spacing.sm)
        }
    }

    private func card(for account: Account, switchable: Bool) -> some View {
        HStack(spacing: MailTheme.Spacing.sm + MailTheme.Spacing.xxs) {
            SettingsAccountAvatar(label: account.label, tint: environment.accountTint(for: account.id))
            VStack(alignment: .leading, spacing: 0) {
                Text(account.label)
                    .textStyle(MailTheme.Typography.headline)
                    .foregroundStyle(MailTheme.Color.ink)
                Text(Self.caption(for: account))
                    .textStyle(MailTheme.Typography.caption)
                    .foregroundStyle(MailTheme.Color.ink3)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if switchable {
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(MailTheme.Color.ink3)
                    .accessibilityHidden(true)
            }
        }
        .padding(MailTheme.Spacing.sm + MailTheme.Spacing.xxs)
        .background(MailTheme.Color.surface, in: RoundedRectangle(cornerRadius: MailTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: MailTheme.Radius.md)
                .strokeBorder(MailTheme.Color.line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: MailTheme.Radius.md))
    }

    /// The card's caption: the server the account talks to.
    static func caption(for account: Account) -> String {
        account.origin.host ?? account.origin.absoluteString
    }

    private var pickedAccountID: Binding<Account.ID> {
        Binding(
            get: { environment.selectedAccountID ?? environment.accountIDs.first ?? "" },
            set: { environment.selectAccountFromSettings($0) }
        )
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    @Environment(AppEnvironment.self) private var environment
    let route: SettingsRoute

    var body: some View {
        let accountLabel = environment.selectedGraph?.account.label
        switch route {
        case .general:
            GeneralSettingsPage(breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: nil))
        case .notifications:
            NotificationSettingsPane(
                environment: environment,
                breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: nil)
            )
        case .privacy:
            PrivacySettingsPane(
                usage: environment.usage,
                breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: nil)
            )
        case .account:
            if let graph = environment.selectedGraph {
                AccountSettingsPage(
                    account: graph.account,
                    mail: graph.mail,
                    breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: nil)
                )
            }
        case .signatures:
            SignaturesSettingsPage(breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: nil))
        case .domain(let domainID, let page):
            let item = environment.selectedAccountID
                .flatMap { environment.settingsDomains(accountID: $0).first { $0.id == domainID } }
            if let item {
                DomainSettingsPlaceholderPage(
                    item: item,
                    page: page,
                    breadcrumb: route.breadcrumb(accountLabel: accountLabel, domainName: item.domain.name)
                )
            }
        }
    }
}
