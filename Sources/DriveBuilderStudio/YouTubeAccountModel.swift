import AppKit
import DriveBuilder
import Foundation
import Observation

/// The YouTube sign-in, shared by the settings window and the journey
/// windows' YouTube sections: which OAuth client is set up, who's signed
/// in, and the authenticator the API calls get their tokens from.
@Observable
final class YouTubeAccountModel {
    let authenticator: YouTubeAuthenticator

    private(set) var client: YouTubeClientCredentials?
    private(set) var channel: YouTubeChannel?
    private(set) var isSignedIn = false
    /// A sign-in is waiting on the browser.
    private(set) var isSigningIn = false
    var error: String?

    init(authenticator: YouTubeAuthenticator = YouTubeAuthenticator()) {
        self.authenticator = authenticator
    }

    /// Reads the saved credentials, for the view's `task`.
    func task() async {
        await reload()
    }

    func saveClientButtonTapped(clientID: String, clientSecret: String) async {
        let client = YouTubeClientCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        await saveClient(client)
    }

    /// The user picked a `client_secret_….json` downloaded from the Google
    /// Cloud console.
    func clientFileChosen(_ url: URL) async {
        do {
            let client = try YouTubeClientCredentials(googleClientFile: Data(contentsOf: url))
            await saveClient(client)
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Opens Google's sign-in page in the default browser and waits for
    /// the account to come back.
    func signInButtonTapped() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        do {
            channel = try await authenticator.signIn { url in
                _ = await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            }
            isSignedIn = true
        } catch {
            self.error = String(describing: error)
        }
    }

    func signOutButtonTapped() async {
        error = nil
        do {
            try await authenticator.signOut()
            await reload()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func saveClient(_ client: YouTubeClientCredentials) async {
        error = nil
        do {
            try await authenticator.saveClient(client)
            await reload()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func reload() async {
        do {
            let credentials = try await authenticator.credentials()
            client = credentials.client
            channel = credentials.channel
            isSignedIn = credentials.isSignedIn
        } catch {
            self.error = String(describing: error)
        }
    }
}
