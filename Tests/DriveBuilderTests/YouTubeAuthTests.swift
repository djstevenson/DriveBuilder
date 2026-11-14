import Foundation
import Synchronization
import Testing

@testable import DriveBuilder

private func temporaryCredentialStore() throws -> (YouTubeCredentialStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "youtube-auth-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (YouTubeCredentialStore(fileURL: directory.appending(path: "nested/youtube.json")), directory)
}

private let testClient = YouTubeClientCredentials(
    clientID: "12345-abc.apps.googleusercontent.com", clientSecret: "GOCSPX-secret")

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Test func pkceChallengeMatchesTheRFCExample() {
    // RFC 7636 appendix B.
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    // Fresh verifiers are 43 URL-safe characters and differ each time.
    let fresh = PKCE()
    #expect(fresh.verifier.count == 43)
    #expect(fresh.verifier != PKCE().verifier)
    #expect(fresh.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

@Test func readsGoogleClientFiles() throws {
    let installed = json([
        "installed": [
            "client_id": "id.apps.googleusercontent.com", "client_secret": "GOCSPX-x",
            "redirect_uris": ["http://localhost"],
        ]
    ])
    let client = try YouTubeClientCredentials(googleClientFile: installed)
    #expect(client == YouTubeClientCredentials(clientID: "id.apps.googleusercontent.com", clientSecret: "GOCSPX-x"))

    #expect(throws: YouTubeAuthError.unrecognisedClientFile) {
        try YouTubeClientCredentials(googleClientFile: json(["something": "else"]))
    }
}

@Test func credentialStoreRoundTripsAndKeepsTheFilePrivate() throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try store.load() == YouTubeCredentials())

    let expires = try Date("2026-11-14T12:00:00Z", strategy: .iso8601)
    let credentials = YouTubeCredentials(
        client: testClient,
        token: YouTubeToken(accessToken: "ya29.a", expiresAt: expires, refreshToken: "1//r"),
        channel: YouTubeChannel(id: "UC1", title: "Test Drives"))
    try store.save(credentials)
    #expect(try store.load() == credentials)

    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path())
    #expect((attributes[.posixPermissions] as? Int) == 0o600)

    try store.update { $0.token = nil }
    #expect(try store.load().token == nil)
    #expect(try store.load().channel?.title == "Test Drives")
}

@Test func tokensExpireAMinuteEarly() {
    let now = Date()
    let token = YouTubeToken(accessToken: "a", expiresAt: now.addingTimeInterval(3600), refreshToken: "r")
    #expect(!token.isExpired(at: now))
    #expect(token.isExpired(at: now.addingTimeInterval(3600 - 30)))
    #expect(token.isExpired(at: now.addingTimeInterval(4000)))
}

@Test func loopbackServerHandsOverTheRedirectQuery() async throws {
    let server = try await LoopbackRedirectServer()
    defer { server.stop() }
    #expect(server.port != 0)
    #expect(server.redirectURI == "http://127.0.0.1:\(server.port)")

    async let query = server.callback()
    let url = URL(string: "\(server.redirectURI)/?state=xyz&code=4%2Fabc&scope=youtube")!
    let (body, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self).contains("Signed in"))
    #expect(try await query == ["state": "xyz", "code": "4/abc", "scope": "youtube"])
}

@Test func loopbackServerIgnoresOtherRequests() async throws {
    let server = try await LoopbackRedirectServer()
    defer { server.stop() }
    let (_, response) = try await URLSession.shared.data(
        from: URL(string: "\(server.redirectURI)/favicon.ico")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 404)
}

@Test func signsInThroughTheBrowserAndLoopback() async throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = "sign-in-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }

    let authenticator = YouTubeAuthenticator(
        store: store, session: StubURLProtocol.session(),
        endpoints: .init(
            authorization: URL(string: "https://\(host)/auth")!,
            token: URL(string: "https://\(host)/token")!,
            revoke: URL(string: "https://\(host)/revoke")!,
            channels: URL(string: "https://\(host)/channels")!))

    // Not set up yet: no client, no sign-in.
    await #expect(throws: YouTubeAuthError.noClient) {
        try await authenticator.accessToken()
    }
    try await authenticator.saveClient(testClient)
    await #expect(throws: YouTubeAuthError.notSignedIn) {
        try await authenticator.accessToken()
    }

    // The stub token endpoint checks the code and that the verifier
    // matches the challenge the sign-in page was opened with.
    let challengeSeen = Mutex<String?>(nil)
    StubURLProtocol.register(host: host) { request, body in
        switch request.url?.path() {
        case "/token":
            let fields = formFields(body)
            #expect(fields["grant_type"] == "authorization_code")
            #expect(fields["code"] == "4/the-code")
            #expect(fields["client_id"] == testClient.clientID)
            #expect(fields["client_secret"] == testClient.clientSecret)
            #expect(fields["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
            let verifier = fields["code_verifier"] ?? ""
            #expect(PKCE(verifier: verifier).challenge == challengeSeen.withLock { $0 })
            return (
                200,
                json([
                    "access_token": "ya29.first", "expires_in": 3599, "refresh_token": "1//refresh",
                    "scope": YouTubeAuthenticator.scope, "token_type": "Bearer",
                ])
            )
        case "/channels":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.first")
            #expect(request.url?.query()?.contains("mine=true") == true)
            return (200, json(["items": [["id": "UCtest", "snippet": ["title": "Test Drives"]]]]))
        default:
            return (404, Data())
        }
    }

    // The "browser": read the state and challenge from the sign-in page's
    // URL, then follow the redirect back with a code.
    let channel = try await authenticator.signIn { url in
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value
        }
        #expect(url.host() == host)
        #expect(query["client_id"] == testClient.clientID)
        #expect(query["scope"] == YouTubeAuthenticator.scope)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        challengeSeen.withLock { $0 = query["code_challenge"] }
        let redirect = URL(string: "\(query["redirect_uri"]!)/?state=\(query["state"]!)&code=4%2Fthe-code")!
        _ = try? await URLSession.shared.data(from: redirect)
    }
    #expect(channel == YouTubeChannel(id: "UCtest", title: "Test Drives"))

    let credentials = try store.load()
    #expect(credentials.token?.accessToken == "ya29.first")
    #expect(credentials.token?.refreshToken == "1//refresh")
    #expect(credentials.channel == channel)
    #expect(credentials.isSignedIn)
    #expect(try await authenticator.accessToken() == "ya29.first")
}

@Test func rejectsARedirectWithTheWrongState() async throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try store.save(YouTubeCredentials(client: testClient))
    let authenticator = YouTubeAuthenticator(store: store, session: StubURLProtocol.session())

    await #expect(throws: YouTubeAuthError.stateMismatch) {
        try await authenticator.signIn { url in
            let redirectURI = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "redirect_uri" }!.value!
            _ = try? await URLSession.shared.data(
                from: URL(string: "\(redirectURI)/?state=forged&code=4%2Fx")!)
        }
    }
    #expect(try store.load().token == nil)
}

@Test func reportsASignInTheUserDeclined() async throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try store.save(YouTubeCredentials(client: testClient))
    let authenticator = YouTubeAuthenticator(store: store, session: StubURLProtocol.session())

    await #expect(throws: YouTubeAuthError.signInDenied("access_denied")) {
        try await authenticator.signIn { url in
            let redirectURI = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "redirect_uri" }!.value!
            _ = try? await URLSession.shared.data(
                from: URL(string: "\(redirectURI)/?error=access_denied")!)
        }
    }
}

@Test func refreshesAnExpiredAccessToken() async throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = "refresh-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }

    try store.save(
        YouTubeCredentials(
            client: testClient,
            token: YouTubeToken(
                accessToken: "ya29.old", expiresAt: Date().addingTimeInterval(-10),
                refreshToken: "1//refresh")))
    let authenticator = YouTubeAuthenticator(
        store: store, session: StubURLProtocol.session(),
        endpoints: .init(
            authorization: URL(string: "https://\(host)/auth")!,
            token: URL(string: "https://\(host)/token")!,
            revoke: URL(string: "https://\(host)/revoke")!,
            channels: URL(string: "https://\(host)/channels")!))

    StubURLProtocol.register(host: host) { request, body in
        let fields = formFields(body)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "1//refresh")
        #expect(fields["client_secret"] == testClient.clientSecret)
        // Google leaves the refresh token out of refresh responses.
        return (200, json(["access_token": "ya29.new", "expires_in": 3599, "token_type": "Bearer"]))
    }

    #expect(try await authenticator.accessToken() == "ya29.new")
    let token = try #require(try store.load().token)
    #expect(token.accessToken == "ya29.new")
    #expect(token.refreshToken == "1//refresh")
    #expect(!token.isExpired())

    // A revoked refresh token surfaces Google's explanation.
    StubURLProtocol.register(host: host) { _, _ in
        (400, json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."]))
    }
    try store.update { $0.token?.expiresAt = Date().addingTimeInterval(-10) }
    await #expect(
        throws: YouTubeAuthError.tokenRequestFailed(
            status: 400, message: "invalid_grant: Token has been expired or revoked.")
    ) {
        try await authenticator.accessToken()
    }
}

@Test func signingOutRevokesAndForgetsTheToken() async throws {
    let (store, directory) = try temporaryCredentialStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = "sign-out-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }

    try store.save(
        YouTubeCredentials(
            client: testClient,
            token: YouTubeToken(accessToken: "a", expiresAt: Date(), refreshToken: "1//refresh"),
            channel: YouTubeChannel(id: "UC1", title: "Test Drives")))
    let authenticator = YouTubeAuthenticator(
        store: store, session: StubURLProtocol.session(),
        endpoints: .init(
            authorization: URL(string: "https://\(host)/auth")!,
            token: URL(string: "https://\(host)/token")!,
            revoke: URL(string: "https://\(host)/revoke")!,
            channels: URL(string: "https://\(host)/channels")!))

    let revoked = Mutex<String?>(nil)
    StubURLProtocol.register(host: host) { request, body in
        #expect(request.url?.path() == "/revoke")
        revoked.withLock { $0 = formFields(body)["token"] }
        return (200, Data("{}".utf8))
    }

    try await authenticator.signOut()
    #expect(revoked.withLock { $0 } == "1//refresh")
    let credentials = try store.load()
    #expect(credentials.token == nil)
    #expect(credentials.channel == nil)
    // The client itself stays, ready for the next sign-in.
    #expect(credentials.client == testClient)
}
