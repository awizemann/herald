import HeraldKit
import SwiftUI

/// ⌘, — the app's only preferences window. One pane for now (Mailboxes), kept as
/// a `Form`/`.formStyle(.grouped)` so it is a stock macOS settings window rather
/// than a hand-drawn one.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            MailboxSettingsPane(model: environment.mail)
                .tabItem { Label("Mailboxes", systemImage: "tray.2") }
        }
        .frame(width: 460, height: 320)
    }
}

/// Per-mailbox chip colour. Changes write straight through the view-model, which
/// both persists them and is observed by the open conversation list — so the rows
/// repaint while this window is still up.
struct MailboxSettingsPane: View {
    let model: MailViewModel?

    var body: some View {
        Form {
            if let model, model.mailboxes.isEmpty == false {
                ForEach(model.mailboxes) { mailbox in
                    MailboxColorRow(model: model, mailbox: mailbox)
                }
            } else {
                // Not an error: Settings can be opened before an account is
                // restored, and an empty Form reads as a broken pane.
                Text("Mailboxes appear here once an account is signed in.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MailboxColorRow: View {
    let model: MailViewModel
    let mailbox: Mailbox

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("Color", selection: selectedToken) {
                    ForEach(MailTheme.mailboxPalette) { tint in
                        // The swatch is decorative; the row's name is what
                        // VoiceOver and Voice Control actually get.
                        Label {
                            Text(tint.displayName)
                        } icon: {
                            Circle().fill(tint.color)
                        }
                        .accessibilityLabel(tint.displayName)
                        .tag(tint.name)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Button("Reset to Default") {
                    model.setMailboxColorToken(nil, for: mailbox.id)
                }
                .disabled(model.hasMailboxColorOverride(mailbox.id) == false)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(mailbox.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var name: String {
        mailbox.displayName.isEmpty ? mailbox.address : mailbox.displayName
    }

    /// Reads the RESOLVED token (override or default) so the popup always shows
    /// what the chip is actually drawn in, and writing one records an override.
    private var selectedToken: Binding<String> {
        Binding(
            get: { model.mailboxColorToken(for: mailbox.id) ?? MailTheme.mailboxPalette[0].name },
            set: { model.setMailboxColorToken($0, for: mailbox.id) }
        )
    }
}
