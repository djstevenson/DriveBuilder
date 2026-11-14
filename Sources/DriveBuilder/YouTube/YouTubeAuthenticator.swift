import Foundation

package enum YouTubeAuthError: Error, CustomStringConvertible, Equatable {
    /// No OAuth client has been entered in the settings yet.
    case noClient
    /// No one has signed in (or they've signed out).
    case notSignedIn
    /// The imported file isn't a Google OAuth client file.
    case unrecognisedClientFile
    /// The redirect came back with a different `state` than the sign-in
    /// sent: not our sign-in.
    case stateMismatch
    /// Google reported an error on the redirect, e.g. `access_denied`.
    case signInDenied(String)
    /// The token endpoint answered with something other than tokens.
    case tokenRequestFailed(status: Int, message: String)
    /// The signed-in Google account has no YouTube channel to upload to.
    case noChannel

    package var description: String {
        switch self {
        case .noClient:
            "Enter the Google OAuth client ID and secret in Settings first."
        case .notSignedIn:
            "Not signed in to YouTube."
        case .unrecognisedClientFile:
            "That file isn't a Google OAuth client file (it should have an \"installed\" entry)."
        case .stateMismatch:
            "The sign-in response didn't match the request that was sent."
        case .signInDenied(let reason):
            "Google refused the sign-in: \(reason)"
        case .tokenRequestFailed(let status, let message):
            "Google's token request failed (HTTP \(status)): \(message)"
        case .noChannel:
            "That Google account has no YouTube channel; create one in YouTube first."
        }
    }
}

/// Signs in to YouTube as a Google "Desktop app" OAuth client and keeps
/// the resulting tokens fresh. The sign-in opens Google's page in the
/// browser and takes the code back over a loopback redirect, with PKCE.
///
/// An actor so that two callers wanting an access token at once share one
/// refresh rather than racing.
package actor YouTubeAuthenticator {
    /// The one scope needed: it covers uploading, editing videos, and
    /// managing playlists.
    package static let scope = "https://www.googleapis.com/auth/youtube"

    /// Google's endpoints, replaceable in tests.
    package struct Endpoints: Sendable {
        package var authorization: URL
        package var token: URL
        package var revoke: URL
        package var channels: URL

        package init(authorization: URL, token: URL, revoke: URL, channels: URL) {
            self.authorization = authorization
            self.token = token
            self.revoke = revoke
            self.channels = channels
        }

        package static let google = Endpoints(
            authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            token: URL(string: "https://oauth2.googleapis.com/token")!,
            revoke: URL(string: "https://oauth2.googleapis.com/revoke")!,
            channels: URL(string: "https://www.googleapis.com/youtube/v3/channels")!)
    }

    private let store: YouTubeCredentialStore
    private let session: URLSession
    private let endpoints: Endpoints

    package init(
        store: YouTubeCredentialStore = .standard(), session: URLSession = .shared,
        endpoints: Endpoints = .google
    ) {
        self.store = store
        self.session = session
        self.endpoints = endpoints
    }

    // MARK: - Credentials

    package func credentials() throws -> YouTubeCredentials {
        try store.load()
    }

    /// Replaces the OAuth client. Any sign-in belonged to the old client,
    /// so it's forgotten too.
    package func saveClient(_ client: YouTubeClientCredentials) throws {
        try store.update { credentials in
            credentials.client = client
            credentials.token = nil
            credentials.channel = nil
        }
    }

    // MARK: - Sign in and out

    /// Runs a sign-in: `openURL` is given Google's sign-in page to show
    /// the user (in their browser); when they've chosen an account and
    /// allowed access, the redirect comes back here, the code is exchanged
    /// for tokens, and the account's channel looked up and saved. Returns
    /// that channel.
    package func signIn(openURL: @Sendable (URL) async -> Void) async throws -> YouTubeChannel {
        guard let client = try store.load().client else { throw YouTubeAuthError.noClient }

        let server = try await LoopbackRedirectServer()
        defer { server.stop() }
        let pkce = PKCE()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        let url = Self.authorizationURL(
            endpoint: endpoints.authorization, client: client, redirectURI: server.redirectURI,
            pkce: pkce, state: state)

        async let redirect = server.callback()
        await openURL(url)
        let query = try await redirect

        if let error = query["error"] { throw YouTubeAuthError.signInDenied(error) }
        guard query["state"] == state else { throw YouTubeAuthError.stateMismatch }
        guard let code = query["code"] else { throw YouTubeAuthError.signInDenied("no code") }

        let token = try await requestToken(
            client: client,
            form: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": server.redirectURI, "code_verifier": pkce.verifier,
            ], previousRefreshToken: nil)
        let channel = try await fetchChannel(accessToken: token.accessToken)
        try store.update { credentials in
            credentials.token = token
            credentials.channel = channel
        }
        return channel
    }

    /// Forgets the sign-in, asking Google to revoke its tokens first
    /// (best effort: the local tokens go either way).
    package func signOut() async throws {
        let credentials = try store.load()
        if let token = credentials.token {
            var request = URLRequest(url: endpoints.revoke)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncode(["token": token.refreshToken]).utf8)
            _ = try? await session.data(for: request)
        }
        try store.update { credentials in
            credentials.token = nil
            credentials.channel = nil
        }
    }

    // MARK: - Access tokens

    /// A valid access token for an API request, refreshed first if the
    /// saved one has (nearly) expired.
    package func accessToken() async throws -> String {
        let credentials = try store.load()
        guard let client = credentials.client else { throw YouTubeAuthError.noClient }
        guard let token = credentials.token else { throw YouTubeAuthError.notSignedIn }
        guard token.isExpired() else { return token.accessToken }

        let refreshed = try await requestToken(
            client: client,
            form: ["grant_type": "refresh_token", "refresh_token": token.refreshToken],
            previousRefreshToken: token.refreshToken)
        try store.update { $0.token = refreshed }
        return refreshed.accessToken
    }

    /// Posts to the token endpoint and decodes the tokens it returns. A
    /// refresh response usually omits the refresh token, which then stays
    /// as `previousRefreshToken`.
    private func requestToken(
        client: YouTubeClientCredentials, form: [String: String], previousRefreshToken: String?
    ) async throws -> YouTubeToken {
        var fields = form
        fields["client_id"] = client.clientID
        fields["client_secret"] = client.clientSecret

        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw YouTubeAuthError.tokenRequestFailed(
                status: status, message: Self.errorMessage(in: data))
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw YouTubeAuthError.tokenRequestFailed(
                status: status, message: "unexpected response: \(String(decoding: data, as: UTF8.self))")
        }
        guard let refreshToken = decoded.refresh_token ?? previousRefreshToken else {
            throw YouTubeAuthError.tokenRequestFailed(
                status: status, message: "no refresh token was issued")
        }
        return YouTubeToken(
            accessToken: decoded.access_token,
            expiresAt: Date().addingTimeInterval(decoded.expires_in),
            refreshToken: refreshToken)
    }

    /// The signed-in account's own channel.
    private func fetchChannel(accessToken: String) async throws -> YouTubeChannel {
        var components = URLComponents(url: endpoints.channels, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "mine", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw YouTubeAuthError.tokenRequestFailed(
                status: status, message: Self.errorMessage(in: data))
        }

        struct ChannelList: Decodable {
            struct Item: Decodable {
                struct Snippet: Decodable {
                    let title: String
                }
                let id: String
                let snippet: Snippet
            }
            let items: [Item]?
        }
        guard let item = try JSONDecoder().decode(ChannelList.self, from: data).items?.first else {
            throw YouTubeAuthError.noChannel
        }
        return YouTubeChannel(id: item.id, title: item.snippet.title)
    }

    // MARK: - Requests

    /// Google's sign-in page for this client, redirecting back to
    /// `redirectURI`. `access_type=offline` and `prompt=consent` make sure
    /// a refresh token comes back even if the account has allowed this
    /// client before.
    static func authorizationURL(
        endpoint: URL, client: YouTubeClientCredentials, redirectURI: String, pkce: PKCE,
        state: String
    ) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// `application/x-www-form-urlencoded`, in a stable order.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)="
                    + "\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }

    /// Google's error JSON (`error` + `error_description`, or the API's
    /// `error.message`) as a line; the raw body when it's neither.
    static func errorMessage(in data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String {
                let description = object["error_description"] as? String
                return description.map { "\(error): \($0)" } ?? error
            }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
