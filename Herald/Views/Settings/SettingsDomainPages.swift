import HeraldKit
import SwiftUI

/// A domain page (Overview · Mailboxes · Signatures · Remove domain) before its
/// real content exists.
///
/// PLACEHOLDER: phase R8 builds Overview, Mailboxes and Signatures; R9 builds
/// Remove domain. Each replaces its `case` in `SettingsDetail` with its own
/// page, built from the same chrome (`SettingsPage`, `SettingsSection`,
/// `SettingsCard`, `SettingsRow`, `SettingsSourceTag`) — then this file goes.
struct DomainSettingsPlaceholderPage: View {
    let item: SettingsDomainItem
    let page: DomainSettingsPage
    let breadcrumb: String

    var body: some View {
        SettingsPage(title: page.title, breadcrumb: breadcrumb) {
            SettingsCard {
                SettingsRow(
                    title: "Not built yet",
                    note: "This page for \(item.domain.name) is built in phase \(page == .remove ? "R9" : "R8")."
                )
            }
        }
    }
}
