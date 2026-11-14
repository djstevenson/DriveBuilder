import Foundation
import Synchronization
import Testing

@testable import DriveBuilder

/// A client whose API, upload, and token endpoints all answer from the
/// stub at `host`, signed in with a token that doesn't need refreshing.
private func makeClient(host: String, chunkSize: Int = YouTubeClient.defaultChunkSize) throws
    -> (client: YouTubeClient, store: YouTubeCredentialStore, directory: URL)
{
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "youtube-client-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = YouTubeCredentialStore(fileURL: directory.appending(path: "youtube.json"))
    try store.save(
        YouTubeCredentials(
            client: YouTubeClientCredentials(clientID: "id", clientSecret: "secret"),
            token: YouTubeToken(
                accessToken: "ya29.valid", expiresAt: Date().addingTimeInterval(3600),
                refreshToken: "1//refresh")))
    let authenticator = YouTubeAuthenticator(
        store: store, session: StubURLProtocol.session(),
        endpoints: .init(
            authorization: URL(string: "https://\(host)/auth")!,
            token: URL(string: "https://\(host)/token")!,
            revoke: URL(string: "https://\(host)/revoke")!,
            channels: URL(string: "https://\(host)/channels")!))
    let client = YouTubeClient(
        authenticator: authenticator, session: StubURLProtocol.session(),
        apiURL: URL(string: "https://\(host)/youtube/v3")!,
        uploadURL: URL(string: "https://\(host)/upload/youtube/v3/videos")!,
        chunkSize: chunkSize)
    return (client, store, directory)
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func jsonObject(_ data: Data?) -> [String: Any] {
    data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}

private func queryItems(_ request: URLRequest) -> [String: String] {
    var items: [String: String] = [:]
    for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        items[item.name] = item.value
    }
    return items
}

@Test func listsPlaylistsAcrossPages() async throws {
    let host = "playlists-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    StubURLProtocol.register(host: host) { request, _ in
        #expect(request.url?.path() == "/youtube/v3/playlists")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid")
        let query = queryItems(request)
        #expect(query["mine"] == "true")
        #expect(query["part"] == "snippet")
        if query["pageToken"] == nil {
            return StubResponse(
                200,
                json([
                    "items": [
                        ["id": "PL1", "snippet": ["title": "A roads"]],
                        ["id": "PL2", "snippet": ["title": "Motorways"]],
                    ],
                    "nextPageToken": "page2",
                ]))
        }
        #expect(query["pageToken"] == "page2")
        return StubResponse(200, json(["items": [["id": "PL3", "snippet": ["title": "Wales"]]]]))
    }

    let playlists = try await client.playlists()
    #expect(playlists == [
        YouTubePlaylist(id: "PL1", title: "A roads"), YouTubePlaylist(id: "PL2", title: "Motorways"),
        YouTubePlaylist(id: "PL3", title: "Wales"),
    ])
}

@Test func createsAPlaylist() async throws {
    let host = "create-playlist-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    StubURLProtocol.register(host: host) { request, body in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/youtube/v3/playlists")
        #expect(queryItems(request)["part"] == "snippet,status")
        let sent = jsonObject(body)
        #expect((sent["snippet"] as? [String: Any])?["title"] as? String == "Scotland")
        #expect((sent["status"] as? [String: Any])?["privacyStatus"] as? String == "public")
        return StubResponse(200, json(["id": "PLnew", "snippet": ["title": "Scotland"]]))
    }

    #expect(try await client.createPlaylist(title: "Scotland") == YouTubePlaylist(id: "PLnew", title: "Scotland"))
}

@Test func readsAndUpdatesAVideoKeepingItsOtherFields() async throws {
    let host = "video-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    let updated = Mutex<[String: Any]?>(nil)
    StubURLProtocol.register(host: host) { request, body in
        #expect(request.url?.path() == "/youtube/v3/videos")
        switch request.httpMethod {
        case "GET":
            #expect(queryItems(request)["part"] == "snippet,status")
            guard queryItems(request)["id"] == "vid1" else {
                return StubResponse(200, json(["items": []]))
            }
            return StubResponse(
                200,
                json([
                    "items": [
                        [
                            "id": "vid1",
                            "snippet": [
                                "title": "Old title", "description": "Old text", "categoryId": "22",
                                "tags": ["driving"],
                            ],
                            "status": [
                                "privacyStatus": "private", "uploadStatus": "processed",
                                "embeddable": true, "selfDeclaredMadeForKids": false,
                                "publishAt": "2027-01-01T00:00:00Z",
                            ],
                        ]
                    ]
                ]))
        case "PUT":
            #expect(queryItems(request)["part"] == "snippet,status")
            updated.withLock { $0 = jsonObject(body) }
            return StubResponse(200, body ?? Data())
        default:
            return StubResponse(405, Data())
        }
    }

    let video = try #require(try await client.video(id: "vid1"))
    #expect(video.id == "vid1")
    #expect(video.metadata == .init(title: "Old title", description: "Old text", privacy: .private))
    #expect(video.uploadStatus == "processed")
    #expect(try await client.video(id: "gone") == nil)

    try await client.updateVideo(
        id: "vid1", metadata: .init(title: "New title", description: "New text", privacy: .public))
    let sent = try #require(updated.withLock { $0 })
    #expect(sent["id"] as? String == "vid1")
    let snippet = sent["snippet"] as? [String: Any]
    #expect(snippet?["title"] as? String == "New title")
    #expect(snippet?["description"] as? String == "New text")
    // YouTube insists on the category and would drop the tags otherwise.
    #expect(snippet?["categoryId"] as? String == "22")
    #expect(snippet?["tags"] as? [String] == ["driving"])
    let status = sent["status"] as? [String: Any]
    #expect(status?["privacyStatus"] as? String == "public")
    #expect(status?["embeddable"] as? Bool == true)
    #expect(status?["selfDeclaredMadeForKids"] as? Bool == false)
    // A scheduled publish time can't go back with a public status.
    #expect(status?["publishAt"] == nil)
}

@Test func managesPlaylistMemberships() async throws {
    let host = "memberships-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    let deleted = Mutex<String?>(nil)
    StubURLProtocol.register(host: host) { request, body in
        #expect(request.url?.path() == "/youtube/v3/playlistItems")
        let query = queryItems(request)
        switch request.httpMethod {
        case "GET":
            #expect(query["videoId"] == "vid1")
            return StubResponse(
                200, json(["items": query["playlistId"] == "PL1" ? [["id": "item-pl1"]] : []]))
        case "POST":
            let snippet = jsonObject(body)["snippet"] as? [String: Any]
            #expect(snippet?["playlistId"] as? String == "PL2")
            let resource = snippet?["resourceId"] as? [String: Any]
            #expect(resource?["kind"] as? String == "youtube#video")
            #expect(resource?["videoId"] as? String == "vid1")
            return StubResponse(200, json(["id": "item-pl2"]))
        case "DELETE":
            deleted.withLock { $0 = query["id"] }
            return StubResponse(204, Data())
        default:
            return StubResponse(405, Data())
        }
    }

    let playlists = [YouTubePlaylist(id: "PL1", title: "A"), YouTubePlaylist(id: "PL2", title: "B")]
    #expect(try await client.memberships(videoID: "vid1", in: playlists) == [.init(id: "item-pl1", playlistID: "PL1")])
    #expect(try await client.addToPlaylist(videoID: "vid1", playlistID: "PL2") == .init(id: "item-pl2", playlistID: "PL2"))
    try await client.removeFromPlaylist(membershipID: "item-pl1")
    #expect(deleted.withLock { $0 } == "item-pl1")
}

@Test func refreshesTheTokenWhenYouTubeRejectsIt() async throws {
    let host = "reject-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, store, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    StubURLProtocol.register(host: host) { request, body in
        if request.url?.path() == "/token" {
            #expect(formFields(body)["grant_type"] == "refresh_token")
            return StubResponse(200, json(["access_token": "ya29.fresh", "expires_in": 3599]))
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fresh" else {
            return StubResponse(401, json(["error": ["message": "Invalid Credentials"]]))
        }
        return StubResponse(200, json(["items": [["id": "PL1", "snippet": ["title": "A roads"]]]]))
    }

    #expect(try await client.playlists().map(\.id) == ["PL1"])
    #expect(try store.load().token?.accessToken == "ya29.fresh")
}

@Test func reportsYouTubeErrors() async throws {
    let host = "errors-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }

    StubURLProtocol.register(host: host) { _, _ in
        StubResponse(
            403,
            json([
                "error": [
                    "code": 403,
                    "message": "The request cannot be completed because you have exceeded your quota.",
                    "errors": [["reason": "quotaExceeded"]],
                ]
            ]))
    }

    await #expect(
        throws: YouTubeAPIError.requestFailed(
            status: 403, message: "The request cannot be completed because you have exceeded your quota.")
    ) {
        try await client.playlists()
    }
}

/// A stand-in for Google's resumable upload session: stores what it's
/// sent, answers status queries, and can fail a chunk on demand.
private final class UploadSessionStub: Sendable {
    let total: Int
    let stored = Mutex(Data())
    let contentRanges = Mutex<[String]>([])
    /// Fail the chunk starting at this offset once with a 503.
    let failOnceAt: Int?
    let failed = Mutex(false)

    init(total: Int, initiallyStored: Data = Data(), failOnceAt: Int? = nil) {
        self.total = total
        self.failOnceAt = failOnceAt
        stored.withLock { $0 = initiallyStored }
    }

    func handle(_ request: URLRequest, body: Data?) -> StubResponse {
        let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
        contentRanges.withLock { $0.append(range) }
        let count = stored.withLock { $0.count }
        if range == "bytes */\(total)" {
            return progressResponse(count)
        }
        let parts = range.dropFirst("bytes ".count).split(separator: "/")[0].split(separator: "-")
        let start = Int(parts[0])!
        guard start == count else { return StubResponse(400, Data("bad offset".utf8)) }
        if start == failOnceAt, !failed.withLock({ $0 }) {
            failed.withLock { $0 = true }
            return StubResponse(503, Data())
        }
        let newCount = stored.withLock { stored -> Int in
            stored.append(body ?? Data())
            return stored.count
        }
        return progressResponse(newCount)
    }

    private func progressResponse(_ count: Int) -> StubResponse {
        if count >= total {
            return StubResponse(200, json(["id": "uploaded-video"]))
        }
        return StubResponse(308, Data(), headers: count > 0 ? ["Range": "bytes=0-\(count - 1)"] : [:])
    }
}

private func temporaryMovie(size: Int, in directory: URL) throws -> (URL, Data) {
    var bytes = Data(count: size)
    bytes.withUnsafeMutableBytes { buffer in
        for index in buffer.indices {
            buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
        }
    }
    let url = directory.appending(path: "final.mov")
    try bytes.write(to: url)
    return (url, bytes)
}

@Test func uploadsInChunksAndResumesAfterAFailure() async throws {
    let host = "upload-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let chunk = 256 * 1024
    let (client, _, directory) = try makeClient(host: host, chunkSize: chunk)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (movie, contents) = try temporaryMovie(size: 4 * chunk + 100, in: directory)

    let session = UploadSessionStub(total: contents.count, failOnceAt: 2 * chunk)
    let started = Mutex<[String: Any]?>(nil)
    StubURLProtocol.register(host: host) { request, body in
        switch request.url?.path() {
        case "/upload/youtube/v3/videos":
            #expect(request.httpMethod == "POST")
            #expect(queryItems(request)["uploadType"] == "resumable")
            #expect(request.value(forHTTPHeaderField: "X-Upload-Content-Type") == "video/quicktime")
            #expect(request.value(forHTTPHeaderField: "X-Upload-Content-Length") == "\(contents.count)")
            started.withLock { $0 = jsonObject(body) }
            return StubResponse(200, Data(), headers: ["Location": "https://\(host)/session/abc"])
        case "/session/abc":
            return session.handle(request, body: body)
        default:
            return StubResponse(404, Data())
        }
    }

    let sessionURI = try await client.startUpload(
        fileURL: movie,
        metadata: .init(title: "A338 Northbound", description: "Bournemouth to Salisbury", privacy: .private))
    #expect(sessionURI.absoluteString == "https://\(host)/session/abc")
    let sent = try #require(started.withLock { $0 })
    #expect((sent["snippet"] as? [String: Any])?["title"] as? String == "A338 Northbound")
    #expect((sent["status"] as? [String: Any])?["privacyStatus"] as? String == "private")
    #expect((sent["status"] as? [String: Any])?["selfDeclaredMadeForKids"] as? Bool == false)

    let fractions = Mutex<[Double]>([])
    let videoID = try await client.upload(fileURL: movie, sessionURI: sessionURI) { update in
        if case .fraction(let fraction) = update {
            fractions.withLock { $0.append(fraction) }
        }
    }
    #expect(videoID == "uploaded-video")
    #expect(session.stored.withLock { $0 } == contents)

    let ranges = session.contentRanges.withLock { $0 }
    let total = contents.count
    // A status query first, every chunk in turn, then after the 503 at
    // the third chunk another status query and the chunk again.
    #expect(ranges == [
        "bytes */\(total)",
        "bytes 0-\(chunk - 1)/\(total)",
        "bytes \(chunk)-\(2 * chunk - 1)/\(total)",
        "bytes \(2 * chunk)-\(3 * chunk - 1)/\(total)",
        "bytes */\(total)",
        "bytes \(2 * chunk)-\(3 * chunk - 1)/\(total)",
        "bytes \(3 * chunk)-\(4 * chunk - 1)/\(total)",
        "bytes \(4 * chunk)-\(total - 1)/\(total)",
    ])
    let reported = fractions.withLock { $0 }
    #expect(reported.first == 0)
    #expect(reported.last == 1)
    #expect(reported.allSatisfy { (0...1).contains($0) })
}

@Test func resumesAnUploadFromWhereTheSessionLeftOff() async throws {
    let host = "resume-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let chunk = 256 * 1024
    let (client, _, directory) = try makeClient(host: host, chunkSize: chunk)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (movie, contents) = try temporaryMovie(size: 2 * chunk + 10, in: directory)

    // As if a previous run got 300 KiB in before quitting.
    let already = 300 * 1024
    let session = UploadSessionStub(total: contents.count, initiallyStored: contents.prefix(already))
    StubURLProtocol.register(host: host) { request, body in
        session.handle(request, body: body)
    }

    let fractions = Mutex<[Double]>([])
    let videoID = try await client.upload(
        fileURL: movie, sessionURI: URL(string: "https://\(host)/session/old")!
    ) { update in
        if case .fraction(let fraction) = update {
            fractions.withLock { $0.append(fraction) }
        }
    }
    #expect(videoID == "uploaded-video")
    #expect(session.stored.withLock { $0 } == contents)
    // A status query, then the rest of the file in one short chunk.
    #expect(session.contentRanges.withLock { $0 } == [
        "bytes */\(contents.count)", "bytes \(already)-\(contents.count - 1)/\(contents.count)",
    ])
    // Progress starts from what was already there, not from nothing.
    #expect(fractions.withLock { $0 }.first == Double(already) / Double(contents.count))
}

@Test func anExpiredUploadSessionIsReported() async throws {
    let host = "expired-test.invalid"
    defer { StubURLProtocol.unregister(host: host) }
    let (client, _, directory) = try makeClient(host: host)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (movie, _) = try temporaryMovie(size: 1000, in: directory)

    StubURLProtocol.register(host: host) { _, _ in StubResponse(404, Data()) }

    await #expect(throws: YouTubeAPIError.uploadSessionExpired) {
        try await client.upload(fileURL: movie, sessionURI: URL(string: "https://\(host)/session/old")!)
    }
}

@Test func readsTheNextOffsetFromARangeHeader() {
    let with = HTTPURLResponse(
        url: URL(string: "https://x.invalid")!, statusCode: 308, httpVersion: nil,
        headerFields: ["Range": "bytes=0-262143"])!
    #expect(YouTubeClient.nextOffset(from: with) == 262144)
    let without = HTTPURLResponse(
        url: URL(string: "https://x.invalid")!, statusCode: 308, httpVersion: nil, headerFields: [:])!
    #expect(YouTubeClient.nextOffset(from: without) == nil)
}
