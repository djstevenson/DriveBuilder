import Foundation
import Synchronization

package enum YouTubeAPIError: Error, CustomStringConvertible, Equatable {
    /// YouTube answered with an error status; `message` is its explanation.
    case requestFailed(status: Int, message: String)
    /// The answer wasn't in the shape expected.
    case unexpectedResponse(String)
    /// A resumable upload session is no longer valid (they last about a
    /// week); the upload has to start again.
    case uploadSessionExpired
    /// The upload kept failing after retries.
    case uploadFailed(String)

    package var description: String {
        switch self {
        case .requestFailed(let status, let message): "YouTube request failed (HTTP \(status)): \(message)"
        case .unexpectedResponse(let detail): "Unexpected response from YouTube: \(detail)"
        case .uploadSessionExpired: "The upload session has expired; the upload needs to start again."
        case .uploadFailed(let detail): "The upload failed: \(detail)"
        }
    }
}

/// The YouTube Data API calls the feature needs, over `URLSession` with
/// tokens from a `YouTubeAuthenticator`: playlists, a video's metadata,
/// playlist memberships, and the resumable upload itself.
package struct YouTubeClient: Sendable {
    /// What the user sets on a video: everything else about it is left as
    /// YouTube has it.
    package struct VideoMetadata: Sendable, Equatable {
        package var title: String
        package var description: String
        package var privacy: YouTubeVideo.Privacy

        package init(title: String, description: String, privacy: YouTubeVideo.Privacy) {
            self.title = title
            self.description = description
            self.privacy = privacy
        }
    }

    /// A video as YouTube holds it.
    package struct RemoteVideo: Sendable, Equatable {
        package let id: String
        package let metadata: VideoMetadata
        /// `uploaded` while YouTube is still processing, then `processed`;
        /// `failed` or `rejected` if it went wrong.
        package let uploadStatus: String?
    }

    /// A video's membership of a playlist as YouTube holds it.
    package struct Membership: Sendable, Equatable {
        /// YouTube's playlistItem id, needed to remove it.
        package let id: String
        package let playlistID: String
    }

    /// Google wants chunks in multiples of 256 KiB; 32 MiB keeps progress
    /// and resumption fine-grained enough on a home upload link.
    package static let defaultChunkSize = 32 * 1024 * 1024

    private let authenticator: YouTubeAuthenticator
    private let session: URLSession
    private let apiURL: URL
    private let uploadURL: URL
    let chunkSize: Int

    package init(
        authenticator: YouTubeAuthenticator, session: URLSession = .shared,
        apiURL: URL = URL(string: "https://www.googleapis.com/youtube/v3")!,
        uploadURL: URL = URL(string: "https://www.googleapis.com/upload/youtube/v3/videos")!,
        chunkSize: Int = defaultChunkSize
    ) {
        self.authenticator = authenticator
        self.session = session
        self.apiURL = apiURL
        self.uploadURL = uploadURL
        self.chunkSize = chunkSize
    }

    // MARK: - Playlists

    /// Every playlist on the signed-in channel, in the channel's order.
    package func playlists() async throws -> [YouTubePlaylist] {
        var playlists: [YouTubePlaylist] = []
        var pageToken: String?
        repeat {
            var query = ["part": "snippet", "mine": "true", "maxResults": "50"]
            query["pageToken"] = pageToken
            let page = try await get("playlists", query: query)
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String,
                    let title = (item["snippet"] as? [String: Any])?["title"] as? String
                else { continue }
                playlists.append(YouTubePlaylist(id: id, title: title))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        return playlists
    }

    /// Creates a playlist on the channel. Playlists holding public videos
    /// are themselves public.
    package func createPlaylist(title: String) async throws -> YouTubePlaylist {
        let created = try await send(
            "POST", "playlists", query: ["part": "snippet,status"],
            json: ["snippet": ["title": title], "status": ["privacyStatus": "public"]])
        guard let id = created["id"] as? String else {
            throw YouTubeAPIError.unexpectedResponse("created playlist has no id")
        }
        return YouTubePlaylist(id: id, title: title)
    }

    // MARK: - Videos

    /// The video as YouTube holds it; nil if it's gone (deleted in
    /// YouTube Studio, say).
    package func video(id: String) async throws -> RemoteVideo? {
        try await videoResource(id: id).map(Self.remoteVideo)
    }

    /// Sets the video's title, description, and visibility, leaving its
    /// other fields as they are. YouTube's update replaces the whole
    /// snippet and status, and insists on the snippet's category, so this
    /// reads the current resource and writes it back changed.
    package func updateVideo(id: String, metadata: VideoMetadata) async throws {
        guard var resource = try await videoResource(id: id) else {
            throw YouTubeAPIError.requestFailed(status: 404, message: "video \(id) not found")
        }
        var snippet = resource["snippet"] as? [String: Any] ?? [:]
        snippet["title"] = metadata.title
        snippet["description"] = metadata.description
        var status = resource["status"] as? [String: Any] ?? [:]
        status["privacyStatus"] = metadata.privacy.rawValue
        // publishAt only makes sense alongside a private status that will
        // change later; sending it back with any other status is an error.
        if metadata.privacy != .private { status["publishAt"] = nil }
        resource = ["id": id, "snippet": snippet, "status": status]
        _ = try await send("PUT", "videos", query: ["part": "snippet,status"], json: resource)
    }

    // MARK: - Playlist memberships

    /// Which of `playlists` the video is in. One request per playlist, so
    /// pass the channel's cached list rather than fetching it each time.
    package func memberships(videoID: String, in playlists: [YouTubePlaylist]) async throws
        -> [Membership]
    {
        var memberships: [Membership] = []
        for playlist in playlists {
            let page = try await get(
                "playlistItems",
                query: ["part": "id", "playlistId": playlist.id, "videoId": videoID, "maxResults": "50"])
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                memberships.append(Membership(id: id, playlistID: playlist.id))
            }
        }
        return memberships
    }

    /// Adds the video to the end of a playlist, returning the membership.
    package func addToPlaylist(videoID: String, playlistID: String) async throws -> Membership {
        let created = try await send(
            "POST", "playlistItems", query: ["part": "snippet"],
            json: [
                "snippet": [
                    "playlistId": playlistID,
                    "resourceId": ["kind": "youtube#video", "videoId": videoID],
                ]
            ])
        guard let id = created["id"] as? String else {
            throw YouTubeAPIError.unexpectedResponse("created playlist item has no id")
        }
        return Membership(id: id, playlistID: playlistID)
    }

    /// Removes a membership.
    package func removeFromPlaylist(membershipID: String) async throws {
        _ = try await send("DELETE", "playlistItems", query: ["id": membershipID], json: nil)
    }

    // MARK: - Upload

    /// Opens a resumable upload session for the movie at `fileURL` with
    /// `metadata`, returning the session URI to `upload(fileURL:sessionURI:)`
    /// with. The session lasts about a week, so an interrupted upload can
    /// be continued from the same URI after a relaunch.
    package func startUpload(fileURL: URL, metadata: VideoMetadata) async throws -> URL {
        let size = try Self.fileSize(fileURL)
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "part", value: "snippet,status"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.contentType(for: fileURL), forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "snippet": ["title": metadata.title, "description": metadata.description],
            "status": [
                "privacyStatus": metadata.privacy.rawValue, "selfDeclaredMadeForKids": false,
            ],
        ])

        let (_, response) = try await authorized(request)
        guard let location = response.value(forHTTPHeaderField: "Location"),
            let sessionURI = URL(string: location)
        else {
            throw YouTubeAPIError.unexpectedResponse("upload session has no Location")
        }
        return sessionURI
    }

    /// Sends the movie to an upload session in chunks, picking up where a
    /// previous attempt left off, and returns the new video's id. Reports
    /// progress as the fraction of the file sent. Transient failures are
    /// retried with backoff after asking the session how far it got;
    /// `uploadSessionExpired` means start again with `startUpload`.
    package func upload(
        fileURL: URL, sessionURI: URL, progress: RenderProgressHandler? = nil
    ) async throws -> String {
        let size = try Self.fileSize(fileURL)
        let contentType = Self.contentType(for: fileURL)
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }

        var offset = try await resumeOffset(sessionURI: sessionURI, size: size)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            if case .done(let id) = offset { return id }
            guard case .next(let start) = offset else { continue }
            progress?(.fraction(size == 0 ? 1 : Double(start) / Double(size)))

            try file.seek(toOffset: UInt64(start))
            let chunk = try file.read(upToCount: min(chunkSize, size - start)) ?? Data()
            let end = start + chunk.count - 1

            var request = URLRequest(url: sessionURI)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(start)-\(end)/\(size)", forHTTPHeaderField: "Content-Range")
            do {
                let delegate = UploadProgressDelegate { sent in
                    progress?(.fraction(Double(start + Int(sent)) / Double(size)))
                }
                let (data, response) = try await session.upload(
                    for: request, from: chunk, delegate: delegate)
                guard let http = response as? HTTPURLResponse else {
                    throw YouTubeAPIError.unexpectedResponse("no HTTP response")
                }
                switch http.statusCode {
                case 200, 201:
                    progress?(.fraction(1))
                    return try Self.videoID(in: data)
                case 308:
                    offset = .next(Self.nextOffset(from: http) ?? end + 1)
                    attempt = 0
                case 404, 410:
                    throw YouTubeAPIError.uploadSessionExpired
                case 500...599:
                    throw TransientFailure(message: "HTTP \(http.statusCode)")
                default:
                    throw YouTubeAPIError.requestFailed(
                        status: http.statusCode, message: YouTubeAuthenticator.errorMessage(in: data))
                }
            } catch let failure as TransientFailure {
                offset = try await retry(&attempt, after: failure.message, sessionURI: sessionURI, size: size)
            } catch let error as URLError where error.code != .cancelled {
                offset = try await retry(
                    &attempt, after: error.localizedDescription, sessionURI: sessionURI, size: size)
            }
        }
    }

    private struct TransientFailure: Error {
        let message: String
    }

    private enum UploadOffset {
        case next(Int)
        case done(String)
    }

    /// Waits out a transient failure (2, 4, 8… seconds, five times) and
    /// asks the session where to continue from.
    private func retry(
        _ attempt: inout Int, after message: String, sessionURI: URL, size: Int
    ) async throws -> UploadOffset {
        attempt += 1
        guard attempt <= 5 else { throw YouTubeAPIError.uploadFailed(message) }
        try await Task.sleep(for: .seconds(Double(1 << attempt)))
        return try await resumeOffset(sessionURI: sessionURI, size: size)
    }

    /// Asks the session how much it has: a `bytes */size` PUT answers 308
    /// with a `Range` of what's stored (none for nothing yet), or 200/201
    /// if the upload had in fact completed.
    private func resumeOffset(sessionURI: URL, size: Int) async throws -> UploadOffset {
        var request = URLRequest(url: sessionURI)
        request.httpMethod = "PUT"
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeAPIError.unexpectedResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200, 201: return .done(try Self.videoID(in: data))
        case 308: return .next(Self.nextOffset(from: http) ?? 0)
        case 404, 410: throw YouTubeAPIError.uploadSessionExpired
        case 500...599: throw TransientFailure(message: "HTTP \(http.statusCode)")
        default:
            throw YouTubeAPIError.requestFailed(
                status: http.statusCode, message: YouTubeAuthenticator.errorMessage(in: data))
        }
    }

    /// The byte after the last one a 308's `Range: bytes=0-N` says is
    /// stored; nil when there's no Range (nothing stored yet).
    static func nextOffset(from response: HTTPURLResponse) -> Int? {
        guard let range = response.value(forHTTPHeaderField: "Range"),
            let dash = range.lastIndex(of: "-"), let last = Int(range[range.index(after: dash)...])
        else { return nil }
        return last + 1
    }

    private static func videoID(in data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else {
            throw YouTubeAPIError.unexpectedResponse("completed upload has no video id")
        }
        return id
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? Int) ?? 0
    }

    private static func contentType(for url: URL) -> String {
        url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/*"
    }

    // MARK: - Requests

    private func videoResource(id: String) async throws -> [String: Any]? {
        let page = try await get("videos", query: ["part": "snippet,status", "id": id])
        return (page["items"] as? [[String: Any]])?.first
    }

    private static func remoteVideo(_ resource: [String: Any]) -> RemoteVideo {
        let snippet = resource["snippet"] as? [String: Any] ?? [:]
        let status = resource["status"] as? [String: Any] ?? [:]
        return RemoteVideo(
            id: resource["id"] as? String ?? "",
            metadata: VideoMetadata(
                title: snippet["title"] as? String ?? "",
                description: snippet["description"] as? String ?? "",
                privacy: YouTubeVideo.Privacy(rawValue: status["privacyStatus"] as? String ?? "")
                    ?? .private),
            uploadStatus: status["uploadStatus"] as? String)
    }

    private func get(_ resource: String, query: [String: String]) async throws -> [String: Any] {
        try await send("GET", resource, query: query, json: nil)
    }

    /// Sends an API request with the current access token (refreshing and
    /// retrying once if YouTube rejects it) and returns the JSON object it
    /// answers with (empty for a 204).
    private func send(
        _ method: String, _ resource: String, query: [String: String], json: [String: Any]?
    ) async throws -> [String: Any] {
        var components = URLComponents(
            url: apiURL.appending(path: resource), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let json {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, _) = try await authorized(request)
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeAPIError.unexpectedResponse(String(decoding: data, as: UTF8.self))
        }
        return object
    }

    /// Performs `request` with a bearer token, refreshing it and trying
    /// once more on a 401; throws `requestFailed` for any other error
    /// status.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        var token = try await authenticator.accessToken()
        for attempt in 0..<2 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw YouTubeAPIError.unexpectedResponse("no HTTP response")
            }
            if http.statusCode == 401, attempt == 0 {
                token = try await authenticator.accessToken(forceRefresh: true)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw YouTubeAPIError.requestFailed(
                    status: http.statusCode, message: YouTubeAuthenticator.errorMessage(in: data))
            }
            return (data, http)
        }
        throw YouTubeAPIError.unexpectedResponse("unreachable")
    }
}

/// Reports how much of an upload chunk's body has gone out, for progress
/// finer than one update per chunk.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onBytesSent: @Sendable (Int64) -> Void

    init(onBytesSent: @escaping @Sendable (Int64) -> Void) {
        self.onBytesSent = onBytesSent
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        onBytesSent(totalBytesSent)
    }
}
