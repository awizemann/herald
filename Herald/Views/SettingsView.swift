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
        .frame(width: 640, height: 320)
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
        // One line per mailbox: name + address on the left, colour + reset on the
        // right. An explicit HStack rather than LabeledContent — in a grouped Form
        // LabeledContent stacks its label over its content once the row is tight,
        // which is exactly the wrap the owner asked to remove.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(mailbox.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .fixedSize()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(mailbox.address)")
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
