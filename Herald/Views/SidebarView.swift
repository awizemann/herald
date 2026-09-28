import AppKit
import HeraldKit
import SwiftUI

/// The drill-down sidebar (handoff §3.1): the account card, then ONE of three
/// levels — Domains + Labels, one domain's Mailboxes, one mailbox's Folders.
///
/// A native source list (`List(.sidebar)`) with the system selection. The
/// level is not view state: it is derived from the view-model's scope
/// (``MailViewModel/sidebarLevel``), so it is persisted and restored with the
/// scope, and a scope change from anywhere (a notification click, Hide) moves
/// the sidebar with it. Rows write through the view-model's intents
/// (``MailViewModel/activate(_:)``); nothing here composes a location itself.
///
/// Each level's non-selectable chrome — the back link, the domain / mailbox
/// header, the mailbox filter — rides in the top safe-area inset under the
/// account card, outside the selectable rows (the Settings sidebar's layout).
struct SidebarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ListDensity.storageKey) private var densityRaw = ListDensity.comfortable.rawValue
    @Bindable var model: MailViewModel

    /// A drill row the ARROW KEYS landed on: highlighted, not yet opened
    /// (Return or → opens it). Cleared by any navigation.
    @State private var keyboardHighlight: MailViewModel.SidebarRow?
    @State private var domainFilter = ""
    @State private var mailboxFilter = ""
    /// Set when a click on a label row changed the selection (and so opened
    /// the label), so the same click's tap does not close it again — see
    /// ``labelTapped(_:)``.
    @State private var labelOpenedBySelection = false
    /// A level change the user made HERE, whose header should take VoiceOver
    /// focus once it is on screen.
    @State private var movesFocusOnLevelChange = false
    @AccessibilityFocusState private var focusedLevel: Int?

    var body: some View {
        let level = model.sidebarLevel
        let preferences = environment.domainPreferencesObserved()
        let tint = environment.accountTint(for: model.accountID)
        let monograms = DomainBadgeResolver.monograms(for: model.monogramDomains, accountID: model.accountID, in: preferences)
        let density = ListDensity(rawValue: densityRaw) ?? .comfortable
        List(selection: selection) {
            switch level {
            case .domains:
                domainsLevel(preferences: preferences, tint: tint, monograms: monograms)
            case .mailboxes(let domainID):
                mailboxesLevel(domainID: domainID)
            case .folders(_, let mailboxID):
                foldersLevel(mailboxID: mailboxID)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, SidebarPresentation.itemHeight(for: density))
        .accessibilityIdentifier(AccessibilityID.Sidebar.list)
        // The level swap is the `scope` motion (rows cross-fade); Reduce Motion
        // makes it instant.
        .animation(reduceMotion ? nil : MailTheme.Animation.scope, value: level)
        .onKeyPress(keys: [.return, .rightArrow]) { _ in
            guard let row = keyboardHighlight, row.drillsIn else { return .ignored }
            drill(into: row)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard level != .domains else { return .ignored }
            back()
            return .handled
        }
        .onChange(of: model.location) { keyboardHighlight = nil }
        .onChange(of: level) {
            domainFilter = ""
            mailboxFilter = ""
            if movesFocusOnLevelChange {
                movesFocusOnLevelChange = false
                focusedLevel = level.depth
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SidebarAccountCard(model: model)
                Rectangle()
                    .fill(MailTheme.Color.lineSoft)
                    .frame(height: 1)
                    .padding(.horizontal, SidebarAccountCard.gap)
                    .padding(.bottom, MailTheme.Spacing.sm)
                    .accessibilityHidden(true)
                levelChrome(level, tint: tint, monograms: monograms)
            }
            .animation(reduceMotion ? nil : MailTheme.Animation.scope, value: level)
        }
    }

    // MARK: Selection

    /// The list's selection, read off the view-model (``MailViewModel/sidebarSelection``)
    /// unless the arrow keys are resting on a drill row.
    ///
    /// Tagged `.tag(row)`, never `.tag(Optional(row))` — see "Herald Settings
    /// Window Architecture": an explicitly Optional tag matches nothing.
    private var selection: Binding<MailViewModel.SidebarRow?> {
        Binding(
            get: { keyboardHighlight ?? model.sidebarSelection },
            set: { row in
                guard let row else { return }
                let isPointer = SidebarPresentation.isPointerEvent(NSApp.currentEvent)
                if row.drillsIn, !isPointer {
                    keyboardHighlight = row
                    return
                }
                keyboardHighlight = nil
                if case .label(let id) = row, isPointer {
                    labelOpenedBySelection = model.selectedLabelID != id || model.isShowingDrafts
                }
                if row.drillsIn { movesFocusOnLevelChange = true }
                model.activate(row)
            }
        )
    }

    private func drill(into row: MailViewModel.SidebarRow) {
        keyboardHighlight = nil
        movesFocusOnLevelChange = true
        model.activate(row)
    }

    private func back() {
        keyboardHighlight = nil
        movesFocusOnLevelChange = true
        model.sidebarBack()
    }

    /// A click on a label row. Clicking the OPEN label closes it (handoff: "clicking
    /// it again … clears it") — but a click on a row that is already selected
    /// does not change a `List` selection, so the selection binding never hears
    /// it; this tap does. When the same click DID change the selection (it
    /// opened the label), the binding already acted and the tap stands down.
    /// If the list swallows the click entirely, the tap alone opens/closes.
    private func labelTapped(_ id: String) {
        if labelOpenedBySelection {
            labelOpenedBySelection = false
            return
        }
        model.pendingNavigationSource = .sidebar
        if model.selectedLabelID == id, !model.isShowingDrafts {
            model.clearLabel()
        } else {
            model.activate(.label(id))
        }
    }

    // MARK: Level 1 — Domains + Labels

    @ViewBuilder
    private func domainsLevel(
        preferences: UserDefaults, tint: MailTheme.AccountTint, monograms: [MailDomain.ID: String]
    ) -> some View {
        let visible = SidebarPresentation.visibleDomains(model.domains, accountID: model.accountID, preferences: preferences)
        let filtersDomains = SidebarPresentation.showsDomainFilter(domainCount: visible.count)
        let shown = filtersDomains ? SidebarPresentation.filter(visible, query: domainFilter, name: \.name) : visible
        Section {
            if filtersDomains {
                SidebarFilterField(text: $domainFilter, prompt: "Filter \(visible.count) domains")
            }
            SidebarItem(
                symbol: "tray.2", title: "All domains", isStrong: true,
                unread: model.allDomainsInboxUnread
            )
            .tag(MailViewModel.SidebarRow.allDomains)
            .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "allDomains")
            ForEach(shown) { domain in
                domainRow(domain, tint: tint, monogram: monograms[domain.id] ?? DomainMonogram.derive(from: domain.name))
            }
        } header: {
            HStack {
                SidebarSectionHeader(title: "Domains")
                    .accessibilityFocused($focusedLevel, equals: 1)
                Spacer()
                if !filtersDomains {
                    // Decorative until there are enough domains to need the
                    // field (handoff: the glyph "turns into" it past 8).
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(MailTheme.Color.ink3)
                        .accessibilityHidden(true)
                }
            }
        }
        if !model.labels.isEmpty {
            Section {
                ForEach(model.labels) { label in
                    labelRow(label)
                }
            } header: {
                SidebarSectionHeader(title: MailTheme.labelsSectionTitle)
            }
        }
    }

    private func domainRow(_ domain: MailDomain, tint: MailTheme.AccountTint, monogram: String) -> some View {
        let unread = model.inboxUnreadByDomain[domain.id] ?? 0
        return HStack(spacing: Self.itemGap) {
            DomainBadge(monogram: monogram, tint: tint, size: .sidebar)
            Text(domain.name)
                .textStyle(unread > 0 ? MailTheme.Typography.headline : MailTheme.Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            SidebarCount(unread)
            SidebarChevron()
        }
        .tag(MailViewModel.SidebarRow.domain(domain.id))
        .contextMenu { domainMenu(domain, unread: unread) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel(domain.name, unread: unread))
        .accessibilityHint("Opens this domain's mailboxes")
        .accessibilityAction { drill(into: .domain(domain.id)) }
        .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "domain.\(domain.id)")
    }

    /// Right-click a domain row (handoff §3.1 / 4a-0).
    @ViewBuilder
    private func domainMenu(_ domain: MailDomain, unread: Int) -> some View {
        Button("Open \(domain.name)") { drill(into: .domain(domain.id)) }
        Button("Mark All as Read") {
            model.beginMarkAllAsRead(inDomain: domain.id)
        }
        .disabled(unread == 0)
        Divider()
        Button("Domain Settings…") { openDomainSettings(domain.id) }
        Button("Hide from Herald") {
            Task { await environment.hideDomain(domain.id, accountID: model.accountID) }
        }
    }

    private func labelRow(_ label: MailLabel) -> some View {
        let count = model.threadCount(forLabel: label.id)
        return HStack(spacing: Self.itemGap) {
            // The dot is only a second cue: the name is always beside it.
            Circle()
                .fill(MailTheme.labelTint(for: label.color))
                .frame(width: MailTheme.unreadDotDiameter, height: MailTheme.unreadDotDiameter)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            Text(label.name)
                .textStyle(MailTheme.Typography.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .textStyle(MailTheme.Typography.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { labelTapped(label.id) })
        .tag(MailViewModel.SidebarRow.label(label.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(label.name) label, \(count) conversations" : "\(label.name) label")
        .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "label.\(label.id)")
    }

    // MARK: Level 2 — Mailboxes

    @ViewBuilder
    private func mailboxesLevel(domainID: MailDomain.ID) -> some View {
        let domain = model.domains.first { $0.id == domainID }
        let mailboxes = (domain?.mailboxIDs ?? []).compactMap { id in model.mailboxes.first { $0.id == id } }
        let shown = SidebarPresentation.filter(mailboxes, query: mailboxFilter, name: \.address)
        SidebarItem(symbol: "tray.2", title: "All mailboxes", isStrong: true, unread: model.inboxUnreadByDomain[domainID] ?? 0)
            .tag(MailViewModel.SidebarRow.allMailboxes)
            .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "allMailboxes")
        ForEach(shown) { mailbox in
            mailboxRow(mailbox)
        }
    }

    private func mailboxRow(_ mailbox: Mailbox) -> some View {
        let unread = model.inboxUnreadByMailbox[mailbox.id] ?? 0
        let parts = SidebarPresentation.addressParts(mailbox.address)
        let local = MailTheme.Typography.headline
        let rest = MailTheme.Typography.body
        return HStack(spacing: Self.itemGap) {
            Image(systemName: "at")
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            (Text(parts.local).font(unread > 0 ? local.font : rest.font)
                + Text(parts.domain).font(rest.font).foregroundStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            SidebarCount(unread)
            SidebarChevron()
        }
        .tag(MailViewModel.SidebarRow.mailbox(mailbox.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel(mailbox.address, unread: unread))
        .accessibilityHint("Opens this mailbox's folders")
        .accessibilityAction { drill(into: .mailbox(mailbox.id)) }
        .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "mailbox.\(mailbox.id)")
    }

    // MARK: Level 3 — Folders

    @ViewBuilder
    private func foldersLevel(mailboxID: Mailbox.ID) -> some View {
        ForEach(Self.levelThreeFolders, id: \.self) { folder in
            folderRow(folder, mailboxID: mailboxID)
        }
    }

    /// Inbox, Starred, Sent, Drafts, Archived, Trash (handoff §3.1 level 3).
    static let levelThreeFolders: [MailViewModel.Folder] = [
        .inbox, .conversation(.starred), .conversation(.sent), .drafts,
        .conversation(.archived), .conversation(.trash),
    ]

    private func folderRow(_ folder: MailViewModel.Folder, mailboxID: Mailbox.ID) -> some View {
        let title: String
        let symbol: String
        let count: Int
        let spoken: String
        switch folder {
        case .conversation(let conversation):
            title = MailTheme.title(for: conversation)
            symbol = MailTheme.symbol(for: conversation)
            // Inbox carries its unread (handoff: "Inbox (unread)"); the other
            // conversation folders carry nothing.
            count = conversation == .inbox ? model.inboxUnreadByMailbox[mailboxID] ?? 0 : 0
            spoken = SidebarPresentation.accessibilityLabel(title, unread: count)
        case .drafts:
            title = MailTheme.draftsTitle
            symbol = MailTheme.draftsSymbol
            // A TOTAL: drafts are never unread.
            count = model.draftCount
            spoken = count > 0 ? "\(title), \(count) drafts" : title
        }
        return SidebarItem(symbol: symbol, title: title, isStrong: false, unread: count)
            .tag(MailViewModel.SidebarRow.folder(folder))
            .accessibilityLabel(spoken)
            .accessibilityIdentifier(AccessibilityID.Sidebar.rowPrefix + "folder.\(NavigationPersistence.raw(for: folder))")
    }

    // MARK: Level chrome

    @ViewBuilder
    private func levelChrome(
        _ level: MailViewModel.SidebarLevel, tint: MailTheme.AccountTint, monograms: [MailDomain.ID: String]
    ) -> some View {
        switch level {
        case .domains:
            EmptyView()
        case .mailboxes(let domainID):
            let domain = model.domains.first { $0.id == domainID }
            let name = domain?.name ?? ""
            VStack(alignment: .leading, spacing: 0) {
                SidebarBackLink(title: "Domains", action: back)
                HStack(spacing: Self.itemGap) {
                    DomainBadge(monogram: monograms[domainID] ?? DomainMonogram.derive(from: name), tint: tint, size: .header)
                    Text(name)
                        .textStyle(MailTheme.Typography.headline)
                        .foregroundStyle(MailTheme.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedLevel, equals: 2)
                    Spacer(minLength: 0)
                    Button { openDomainSettings(domainID) } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(MailTheme.Color.ink2)
                    }
                    .buttonStyle(.plain)
                    .iconButtonStyle("Domain Settings…")
                    .accessibilityIdentifier(AccessibilityID.Sidebar.domainSettings)
                }
                .padding(.horizontal, MailTheme.Spacing.lg)
                .padding(.bottom, MailTheme.Spacing.sm)
                SidebarFilterField(
                    text: $mailboxFilter, prompt: "Filter \(domain?.mailboxIDs.count ?? 0) mailboxes"
                )
                .padding(.horizontal, SidebarAccountCard.gap)
                .padding(.bottom, MailTheme.Spacing.sm)
            }
        case .folders(let domainID, let mailboxID):
            let domainName = domainID.flatMap { id in model.domains.first { $0.id == id }?.name }
            let address = model.mailboxes.first { $0.id == mailboxID }?.address ?? ""
            let parts = SidebarPresentation.addressParts(address)
            VStack(alignment: .leading, spacing: 0) {
                SidebarBackLink(title: domainName ?? "Domains", action: back)
                HStack(spacing: Self.itemGap) {
                    if let domainID {
                        DomainBadge(
                            monogram: monograms[domainID] ?? DomainMonogram.derive(from: domainName ?? ""),
                            tint: tint, size: .header
                        )
                    }
                    (Text(parts.local).font(MailTheme.Typography.headline.font)
                        + Text(parts.domain).font(MailTheme.Typography.body.font).foregroundStyle(MailTheme.Color.ink3))
                        .foregroundStyle(MailTheme.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(address)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedLevel, equals: 3)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: MailTheme.hitTarget)
                .padding(.horizontal, MailTheme.Spacing.lg)
                .padding(.bottom, MailTheme.Spacing.sm)
            }
        }
    }

    private func openDomainSettings(_ domainID: MailDomain.ID) {
        environment.showSettings(.domain(domainID, .overview), accountID: model.accountID) { openSettings() }
    }

    /// 10pt between a row's icon and its name (the mock's gap).
    static let itemGap = MailTheme.Spacing.sm + MailTheme.Spacing.xxs
    /// The icon column, so badges, glyphs and dots line their names up.
    static let iconWidth: CGFloat = 18
}

// MARK: - Pieces

/// A row with a leading symbol, a title and an unread count.
private struct SidebarItem: View {
    let symbol: String
    let title: String
    /// The "All …" rows are 600 (the mock's weight for them).
    let isStrong: Bool
    let unread: Int

    var body: some View {
        HStack(spacing: SidebarView.itemGap) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: SidebarView.iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .textStyle(isStrong ? MailTheme.Typography.headline : MailTheme.Typography.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            SidebarCount(unread)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel(title, unread: unread))
    }
}

/// Mono 11/600, hidden at zero. Hierarchical, not a fixed ink: it sits inside
/// a `List` row and must flip with the system selection.
private struct SidebarCount: View {
    let value: Int
    init(_ value: Int) { self.value = value }

    var body: some View {
        if value > 0 {
            Text("\(value)")
                .textStyle(MailTheme.Typography.metaStrong)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct SidebarChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(MailTheme.Typography.caption.font)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// "DOMAINS", "LABELS" — the handoff's uppercase caption, not the source
/// list's default header.
private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .textStyle(MailTheme.Typography.section)
            .foregroundStyle(MailTheme.Color.ink3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "‹ Domains" / "‹ acme.co": 12pt ink2, a real button (28pt tall).
private struct SidebarBackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MailTheme.Spacing.xxs) {
                Image(systemName: "chevron.left")
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textStyle(MailTheme.Typography.snippet)
            .foregroundStyle(MailTheme.Color.ink2)
            .frame(minHeight: MailTheme.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MailTheme.Spacing.md)
        .help("Back to \(title)")
        .accessibilityLabel("Back to \(title)")
        .accessibilityIdentifier(AccessibilityID.Sidebar.back)
    }
}

/// "Filter N mailboxes": 26pt, surface fill, lineSoft ring.
private struct SidebarFilterField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: MailTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MailTheme.Color.ink3)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .textStyle(MailTheme.Typography.snippet)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(AccessibilityID.Sidebar.filter)
        }
        .padding(.horizontal, MailTheme.Spacing.sm)
        .frame(height: Self.height)
        .background(MailTheme.Color.surface, in: RoundedRectangle(cornerRadius: MailTheme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: MailTheme.Radius.sm)
                .strokeBorder(MailTheme.Color.lineSoft, lineWidth: 1)
        }
    }

    static let height: CGFloat = 26
}
