import Foundation
import HeraldKit

/// What Settings › Account's sign-out dialog is about: the account and the name
/// its title shows, both captured when the dialog opens. `id` tells one request
/// from the next, even for the same account.
struct SettingsSignOutPrompt: Equatable, Identifiable {
    let id: UUID
    let accountID: Account.ID
    let accountLabel: String
}

/// The Settings window's state: its route (deep links), the per-account tint the
/// whole app draws, the domains its sidebar lists, and the gated sign-out.
extension AppEnvironment {
    // MARK: - Route

    /// Opens Settings at `route`. SwiftUI's `openSettings` takes no argument, so
    /// the route is set first and the window, opening (or coming forward),
    /// reads it. `open` is the caller's `@Environment(\.openSettings)` —
    /// injected rather than reached for so the route logic is testable.
    ///
    /// `accountID` switches the window to that account first (a domain id only
    /// means anything within its account). An id that is not signed in is
    /// ignored rather than leaving the window on no account.
    func showSettings(_ route: SettingsRoute, accountID: Account.ID? = nil, open: () -> Void) {
        if let accountID, accountID != selectedAccountID, graphs[accountID] != nil {
            selectedAccountID = accountID
        }
        settingsRoute = route
        open()
    }

    /// The page Settings actually draws for the selected account (see
    /// ``SettingsRoute/resolved(hasAccount:visibleDomainIDs:)``).
    var resolvedSettingsRoute: SettingsRoute {
        let visible = selectedAccountID.map { Set(settingsDomains(accountID: $0).map(\.id)) } ?? []
        return settingsRoute.resolved(hasAccount: selectedGraph != nil, visibleDomainIDs: visible)
    }

    /// The Settings account card's switch. A user's choice, so it is recorded
    /// like the main window's switcher. A domain route is dropped back to the
    /// new account's Account page: domain ids belong to one account.
    func selectAccountFromSettings(_ id: Account.ID) {
        guard graphs[id] != nil, id != selectedAccountID else { return }
        selectedAccountID = id
        if settingsRoute.domainID != nil { settingsRoute = .account }
    }

    /// The account's domains the Settings sidebar lists — hidden ones excluded.
    func settingsDomains(accountID: Account.ID) -> [SettingsDomainItem] {
        SettingsDomainItem.visible(
            mailboxes: graphs[accountID]?.mail.mailboxes ?? [],
            accountID: accountID,
            defaults: domainPreferencesObserved()
        )
    }

    // MARK: - Account tint

    /// The account's tint token NAME: the Settings override when there is a
    /// valid one, else the stable hash default (``AccountTintAssignment``).
    ///
    /// OBSERVABLE: it reads ``accountTintRevision``, which every write bumps, so
    /// any view that draws an account's colour through this (or
    /// ``accountTint(for:)``) repaints live when Settings changes it — the
    /// avatar in the Settings card, and R4/R5's sidebar card and own-message
    /// avatars. Never read `account.<id>.tint` from `UserDefaults` directly.
    func accountTintName(for accountID: Account.ID) -> String {
        _ = accountTintRevision
        let override = defaults.string(forKey: AccountTintAssignment.storageKey(accountID: accountID))
        return AccountTintAssignment.token(forAccountID: accountID, override: override)
    }

    /// The tint to draw. Falls back to the first tint only if the name list
    /// and `MailTheme.accountTints` ever disagree (`ThemeTokenTests` pins them).
    func accountTint(for accountID: Account.ID) -> MailTheme.AccountTint {
        MailTheme.accountTint(named: accountTintName(for: accountID)) ?? MailTheme.accountTints[0]
    }

    /// Whether the user picked a colour — what enables Reset.
    func hasAccountTintOverride(_ accountID: Account.ID) -> Bool {
        _ = accountTintRevision
        guard let raw = defaults.string(forKey: AccountTintAssignment.storageKey(accountID: accountID)) else {
            return false
        }
        return AccountTintAssignment.tokenNames.contains(raw)
    }

    /// Records (or, with `nil`, clears — Reset) the account's colour. A name
    /// outside the tint set is refused rather than stored.
    func setAccountTint(_ name: String?, for accountID: Account.ID) {
        let key = AccountTintAssignment.storageKey(accountID: accountID)
        if let name {
            guard AccountTintAssignment.tokenNames.contains(name) else { return }
            defaults.set(name, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        accountTintRevision &+= 1
    }

    // MARK: - Domain preferences

    /// The ONE write path for Herald-only per-domain preferences
    /// (`DomainPreferences`: monogram, includeInAll, countInBadge, notify,
    /// hidden). `write` receives the defaults the preferences live in; after it
    /// runs, every observer repaints (``domainPreferencesRevision``), and the
    /// account's view-model reloads its list, counts and badge — an exclusion
    /// or a hide changes what "All domains" lists. Views never write
    /// `DomainPreferences` directly.
    func updateDomainPreferences(accountID: Account.ID, _ write: (UserDefaults) -> Void) async {
        write(defaults)
        domainPreferencesRevision &+= 1
        await graphs[accountID]?.mail.domainPreferencesDidChange()
        applyDockBadge()
    }

    /// Call from any view body (or computed read) that draws from
    /// `DomainPreferences`, so it re-renders after
    /// ``updateDomainPreferences(accountID:_:)``. Returns the defaults to read.
    func domainPreferencesObserved() -> UserDefaults {
        _ = domainPreferencesRevision
        return defaults
    }

    // MARK: - Sign out (Settings › Account)

    /// "Sign Out…": asks first. Nothing is signed out until
    /// ``confirmSettingsSignOut(_:)``.
    func requestSettingsSignOut(accountID: Account.ID) {
        guard let account = graphs[accountID]?.account else { return }
        let prompt = SettingsSignOutPrompt(id: UUID(), accountID: accountID, accountLabel: account.label)
        settingsSignOutPrompt = prompt
        armedSettingsSignOutID = prompt.id
        isConfirmingSettingsSignOut = true
    }

    /// The dialog's Cancel. Disarms the prompt; the title keeps its text.
    func cancelSettingsSignOut() {
        armedSettingsSignOutID = nil
        isConfirmingSettingsSignOut = false
    }

    /// The dialog's Sign Out, handed the prompt the dialog was drawn for. Signs
    /// out the account that prompt NAMED — not whichever is selected now — and
    /// only while that prompt is still armed: a second confirm (a double click
    /// racing the dismissal), a cancelled prompt or one superseded by a newer
    /// request does nothing.
    func confirmSettingsSignOut(_ prompt: SettingsSignOutPrompt) async {
        guard armedSettingsSignOutID == prompt.id else { return }
        armedSettingsSignOutID = nil
        isConfirmingSettingsSignOut = false
        await signOut(accountID: prompt.accountID)
    }
}
