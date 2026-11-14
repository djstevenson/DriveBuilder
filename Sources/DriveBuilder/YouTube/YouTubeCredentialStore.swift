import Foundation

/// The Google Cloud OAuth client Studio signs in through: a "Desktop app"
/// client's id and secret from the console. Google treats a desktop
/// client's secret as not really secret, but its token endpoint still
/// insists on it, and the repository is public, so it lives in the
/// credentials file rather than the source.
package struct YouTubeClientCredentials: Codable, Sendable, Equatable {
    package let clientID: String
    package let clientSecret: String

    package init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Reads the `client_secret_….json` the console offers at creation,
    /// whose credentials sit under an `installed` key for desktop clients
    /// (or `web` for web ones).
    package init(googleClientFile data: Data) throws {
        struct File: Decodable {
            struct Client: Decodable {
                let client_id: String
                let client_secret: String
            }
            let installed: Client?
            let web: Client?
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard let client = file.installed ?? file.web else {
            throw YouTubeAuthError.unrecognisedClientFile
        }
        self.init(clientID: client.client_id, clientSecret: client.client_secret)
    }
}

/// The tokens from a sign-in: the short-lived access token, when it runs
/// out, and the refresh token that gets another.
package struct YouTubeToken: Codable, Sendable, Equatable {
    package var accessToken: String
    package var expiresAt: Date
    package var refreshToken: String

    package init(accessToken: String, expiresAt: Date, refreshToken: String) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }

    /// Whether the access token should be refreshed before use: expired,
    /// or within a minute of it, so a slow upload chunk doesn't start on a
    /// token that dies under it.
    package func isExpired(at date: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(date) < 60
    }
}

/// The signed-in channel, for the settings to show whose account uploads
/// will go to.
package struct YouTubeChannel: Codable, Sendable, Equatable {
    package let id: String
    package let title: String

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Everything the YouTube feature keeps outside the database and the
/// repository: the OAuth client, the sign-in's tokens, and the channel.
package struct YouTubeCredentials: Codable, Sendable, Equatable {
    package var client: YouTubeClientCredentials?
    package var token: YouTubeToken?
    package var channel: YouTubeChannel?

    package init(
        client: YouTubeClientCredentials? = nil, token: YouTubeToken? = nil,
        channel: YouTubeChannel? = nil
    ) {
        self.client = client
        self.token = token
        self.channel = channel
    }

    package var isSignedIn: Bool { token != nil }
}

/// Reads and writes the credentials file: by default
/// `~/Library/Application Support/DriveBuilder/youtube.json`, created
/// readable by this user only.
///
/// A file rather than the Keychain because Studio is built and run as a
/// bare SPM executable: each rebuild is a new binary to the Keychain,
/// which would ask for permission on every launch.
package struct YouTubeCredentialStore: Sendable {
    package let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The store at the default location for this user.
    package static func standard() -> YouTubeCredentialStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return YouTubeCredentialStore(
            fileURL: support.appending(path: "DriveBuilder/youtube.json"))
    }

    /// The saved credentials; empty when nothing's been set up yet.
    package func load() throws -> YouTubeCredentials {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return YouTubeCredentials()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(YouTubeCredentials.self, from: Data(contentsOf: fileURL))
    }

    /// Writes the credentials, creating the directory if needed and keeping
    /// the file private to this user.
    package func save(_ credentials: YouTubeCredentials) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(credentials).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
    }

    /// Applies `change` to the saved credentials and writes them back.
    package func update(_ change: (inout YouTubeCredentials) -> Void) throws {
        var credentials = try load()
        change(&credentials)
        try save(credentials)
    }
}
