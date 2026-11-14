import DriveBuilder
import SwiftUI
import UniformTypeIdentifiers

/// The settings window's YouTube pane: the Google OAuth client to sign in
/// through, and the sign-in itself.
struct YouTubeSettingsView: View {
    @Environment(YouTubeAccountModel.self) private var account

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isImportingClientFile = false

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientID, prompt: Text("….apps.googleusercontent.com"))
                    .accessibilityIdentifier("youtube-client-id")
                SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
                    .accessibilityIdentifier("youtube-client-secret")
                HStack {
                    Button("Import client_secret.json…") {
                        isImportingClientFile = true
                    }
                    Spacer()
                    Button("Save Client") {
                        Task {
                            await account.saveClientButtonTapped(
                                clientID: clientID, clientSecret: clientSecret)
                        }
                    }
                    .disabled(!hasClientEdits)
                }
            } header: {
                Text("Google API client")
            } footer: {
                Text(
                    "A \u{201C}Desktop app\u{201D} OAuth client from the Google Cloud console, "
                        + "with the YouTube Data API enabled. Saving a new client signs out.")
                .font(.appCaption)
                .foregroundStyle(.secondary)
            }

            Section("YouTube account") {
                if let channel = account.channel {
                    LabeledContent("Signed in as", value: channel.title)
                    Button("Sign Out") {
                        Task { await account.signOutButtonTapped() }
                    }
                } else if account.isSigningIn {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finish signing in in your browser\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Sign In with Google\u{2026}") {
                        Task { await account.signInButtonTapped() }
                    }
                    .disabled(account.client == nil)
                    .help(
                        account.client == nil
                            ? "Save the Google API client first." : "Opens Google's sign-in page in your browser.")
                }
            }

            if let error = account.error {
                Text(error)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fileImporter(
            isPresented: $isImportingClientFile, allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                Task { await account.clientFileChosen(url) }
            }
        }
        .task {
            await account.task()
            showSavedClient()
        }
        .onChange(of: account.client) {
            showSavedClient()
        }
    }

    /// The fields differ from the saved client (or there isn't one yet)
    /// and are both filled in.
    private var hasClientEdits: Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return false }
        return YouTubeClientCredentials(clientID: id, clientSecret: secret) != account.client
    }

    private func showSavedClient() {
        clientID = account.client?.clientID ?? ""
        clientSecret = account.client?.clientSecret ?? ""
    }
}
