import SwiftUI

/// Sign-in: the user's HQBase origin, then the OAuth flow in the browser.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var originText = ""
    @FocusState private var originFocused: Bool

    private var origin: URL? { AppEnvironment.normalizedOrigin(from: originText) }

    var body: some View {
        VStack(spacing: MailTheme.Spacing.lg) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(MailTheme.Typography.heroGlyph)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Connect to HQBase")
                .font(.title2.weight(.semibold))
            Text("Herald works with your own HQBase server. Enter its address to sign in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            TextField("https://mail.example.com", text: $originText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
                .focused($originFocused)
                .onSubmit { signIn() }
                .accessibilityLabel("Server address")

            if let message = environment.signInError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(MailTheme.failure)
                    .frame(maxWidth: 380)
            }

            // Names the step a slow sign-in is on. A spinner alone cannot say
            // whether the server is unreachable or the browser window never came
            // up — which is the whole of issue #9 from the user's side.
            if environment.isSigningIn, let stage = environment.signInStage {
                HStack(spacing: MailTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(stage.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 380)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signing in. \(stage.message)")
            }

            HStack {
                // Cancel is available on BOTH screens while a sign-in runs — the
                // first-run screen is not a sheet, so `dismiss()` would do
                // nothing there — and it cancels the sign-in itself rather than
                // just closing the window over it.
                if environment.isSigningIn {
                    Button("Cancel") {
                        environment.cancelSignIn()
                        // One press, not two: on the sheet, Cancel means "stop
                        // and get out of my way".
                        if isSheet { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel sign-in")
                } else if isSheet {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button {
                    signIn()
                } label: {
                    if environment.isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(origin == nil || environment.isSigningIn)
                .accessibilityLabel(environment.isSigningIn ? "Signing in" : "Sign In")
            }
        }
        .padding(MailTheme.Spacing.xxxl)
        .frame(minWidth: 460, minHeight: 340)
        .onAppear { originFocused = true }
    }

    private func signIn() {
        guard !environment.isSigningIn else { return }
        Task { await environment.signIn(originText: originText) }
    }
}
