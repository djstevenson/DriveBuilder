import DriveBuilder
import Foundation
import Observation
import Synchronization

/// One upload in flight: which journey and which of its final videos.
struct ActiveUpload: Equatable {
    let journeyID: Int64
    let variant: YouTubeVideo.Variant
    let rowID: Int64
}

/// What the user wants a video to be on YouTube: its metadata and which
/// playlists it's in.
struct YouTubeVideoDetails: Equatable {
    var metadata: YouTubeClient.VideoMetadata
    var playlistIDs: Set<String>
}

/// YouTube for the journey windows: the channel's playlists, the one
/// upload at a time (network-bound, so apart from the render queue), and
/// edits to uploaded videos. YouTube is the source of truth; the database
/// is written only once YouTube has accepted a change.
@Observable
final class YouTubeModel {
    let account: YouTubeAccountModel
    let client: YouTubeClient
    let databasePath: String

    private(set) var playlists: [YouTubePlaylist] = []
    private(set) var activeUpload: ActiveUpload?
    /// How much of the active upload's file has been sent, 0...1.
    private(set) var uploadFraction = 0.0
    /// The last upload's failure, until dismissed.
    var uploadError: (journeyID: Int64, message: String)?
    /// Bumped whenever a journey's YouTube records change, so the windows
    /// re-read them.
    private(set) var videosVersion = 0

    private var uploadTask: Task<Void, Never>?

    init(account: YouTubeAccountModel, databasePath: String) {
        self.account = account
        self.databasePath = databasePath
        client = YouTubeClient(authenticator: account.authenticator)
    }

    private var library: JourneyLibrary { JourneyLibrary(databasePath: databasePath) }

    var isUploading: Bool { activeUpload != nil }

    /// Reads the cached playlists, for the app's first window.
    func task() async {
        playlists = (try? await library.youtubePlaylists()) ?? []
    }

    // MARK: - Playlists

    /// Fetches the channel's playlists afresh and caches them.
    func refreshPlaylistsButtonTapped() async throws {
        let fetched = try await client.playlists()
        try await library.replaceYouTubePlaylists(fetched)
        playlists = fetched
    }

    /// Creates a playlist on the channel and adds it to the cache.
    func createPlaylist(title: String) async throws -> YouTubePlaylist {
        let playlist = try await client.createPlaylist(title: title)
        try await library.insertYouTubePlaylist(playlist)
        playlists.append(playlist)
        return playlist
    }

    // MARK: - Uploading

    /// Saves the details as the video's draft and starts uploading the
    /// movie, continuing a previous attempt's session if the same file is
    /// still part-way up. Runs on after the caller returns; the card shows
    /// its progress and `uploadError` its failure.
    func uploadButtonTapped(
        journey: JourneySummary, variant: YouTubeVideo.Variant, details: YouTubeVideoDetails
    ) async {
        guard activeUpload == nil else { return }
        uploadError = nil
        do {
            let row = try await library.saveYouTubeVideo(
                journeyID: journey.id, variant: variant, title: details.metadata.title,
                description: details.metadata.description, privacy: details.metadata.privacy)
            videosVersion += 1
            activeUpload = ActiveUpload(journeyID: journey.id, variant: variant, rowID: row.id)
            uploadFraction = 0
            uploadTask = Task {
                await runUpload(journey: journey, row: row, details: details)
            }
        } catch {
            uploadError = (journey.id, String(describing: error))
        }
    }

    func cancelUploadButtonTapped() {
        uploadTask?.cancel()
    }

    private func runUpload(journey: JourneySummary, row: YouTubeVideo, details: YouTubeVideoDetails) async {
        // Keep the Mac awake: a long movie takes hours on a home link.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Uploading to YouTube")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            activeUpload = nil
            uploadTask = nil
            videosVersion += 1
        }
        do {
            let fileURL = Self.movieURL(journey: journey, variant: row.variant)
            let modified = Self.modificationDate(of: fileURL)
            let videoID = try await send(fileURL: fileURL, modified: modified, row: row, metadata: details.metadata)
            try await library.markYouTubeVideoUploaded(
                id: row.id, videoID: videoID, uploadedAt: Date(), fileModified: modified)
            // A new video has no memberships yet, whatever the old one had.
            var memberships: [YouTubePlaylistItem] = []
            for playlist in playlists where details.playlistIDs.contains(playlist.id) {
                let membership = try await client.addToPlaylist(videoID: videoID, playlistID: playlist.id)
                memberships.append(
                    YouTubePlaylistItem(id: membership.id, videoRowID: row.id, playlistID: playlist.id))
            }
            try await library.replaceYouTubePlaylistItems(videoRowID: row.id, with: memberships)
        } catch is CancellationError {
            // The session stays recorded, so Upload again picks up from here.
        } catch {
            uploadError = (journey.id, String(describing: error))
        }
    }

    /// Opens (or resumes) the upload session and sends the file, starting
    /// a fresh session once if the saved one has expired.
    private func send(
        fileURL: URL, modified: Date?, row: YouTubeVideo, metadata: YouTubeClient.VideoMetadata
    ) async throws -> String {
        var sessionURI: URL?
        if let saved = row.uploadSessionURI, row.uploadedFileModified == modified {
            sessionURI = URL(string: saved)
        }
        for attempt in 0..<2 {
            let uri: URL
            if let sessionURI {
                uri = sessionURI
            } else {
                uri = try await client.startUpload(fileURL: fileURL, metadata: metadata)
                try await library.setYouTubeUploadSession(
                    id: row.id, uri: uri.absoluteString, fileModified: modified)
            }
            do {
                return try await client.upload(fileURL: fileURL, sessionURI: uri, progress: progressHandler())
            } catch YouTubeAPIError.uploadSessionExpired where attempt == 0 {
                sessionURI = nil
                try await library.setYouTubeUploadSession(id: row.id, uri: nil, fileModified: nil)
            }
        }
        throw YouTubeAPIError.uploadSessionExpired
    }

    /// Thins the per-chunk-body progress down to steps worth redrawing
    /// for, and hops them onto the main actor.
    private func progressHandler() -> RenderProgressHandler {
        let last = Mutex(-1.0)
        return { [weak self] update in
            guard case .fraction(let fraction) = update else { return }
            let worthIt = last.withLock { last -> Bool in
                guard fraction >= 1 || fraction - last >= 0.001 else { return false }
                last = fraction
                return true
            }
            guard worthIt else { return }
            Task { @MainActor in
                self?.uploadFraction = fraction
            }
        }
    }

    // MARK: - Editing and refreshing

    /// Saves changed details: to YouTube first when the video's uploaded
    /// (metadata, then playlist memberships added and removed), then to
    /// the database; a draft just updates the database.
    func saveButtonTapped(
        journey: JourneySummary, variant: YouTubeVideo.Variant, row: YouTubeVideo?,
        details: YouTubeVideoDetails
    ) async throws {
        defer { videosVersion += 1 }
        guard let row, let videoID = row.videoID else {
            _ = try await library.saveYouTubeVideo(
                journeyID: journey.id, variant: variant, title: details.metadata.title,
                description: details.metadata.description, privacy: details.metadata.privacy)
            return
        }
        try await client.updateVideo(id: videoID, metadata: details.metadata)
        try await library.updateYouTubeVideo(
            id: row.id, title: details.metadata.title, description: details.metadata.description,
            privacy: details.metadata.privacy, syncedAt: Date())

        let current = try await library.youtubePlaylistItems(videoRowID: row.id)
        for item in current where !details.playlistIDs.contains(item.playlistID) {
            try await client.removeFromPlaylist(membershipID: item.id)
            try await library.deleteYouTubePlaylistItem(id: item.id)
        }
        let inPlaylists = Set(current.map(\.playlistID))
        for playlistID in details.playlistIDs.subtracting(inPlaylists) {
            let membership = try await client.addToPlaylist(videoID: videoID, playlistID: playlistID)
            try await library.insertYouTubePlaylistItem(
                YouTubePlaylistItem(id: membership.id, videoRowID: row.id, playlistID: playlistID))
        }
    }

    /// Re-reads the video from YouTube (title, description, visibility,
    /// processing state, playlists) into the cache. Returns nil if YouTube
    /// no longer has it.
    func refreshButtonTapped(row: YouTubeVideo) async throws -> YouTubeClient.RemoteVideo? {
        guard let videoID = row.videoID else { return nil }
        defer { videosVersion += 1 }
        guard let remote = try await client.video(id: videoID) else { return nil }
        try await library.updateYouTubeVideo(
            id: row.id, title: remote.metadata.title, description: remote.metadata.description,
            privacy: remote.metadata.privacy, syncedAt: Date())
        let memberships = try await client.memberships(videoID: videoID, in: playlists)
        try await library.replaceYouTubePlaylistItems(
            videoRowID: row.id,
            with: memberships.map {
                YouTubePlaylistItem(id: $0.id, videoRowID: row.id, playlistID: $0.playlistID)
            })
        return remote
    }

    /// Drops the record of a video YouTube no longer has.
    func forgetButtonTapped(row: YouTubeVideo) async throws {
        try await library.deleteYouTubeVideo(id: row.id)
        videosVersion += 1
    }

    // MARK: - Files

    static func movieURL(journey: JourneySummary, variant: YouTubeVideo.Variant) -> URL {
        URL(filePath: journey.directory).appending(path: "output/\(variant.fileName)")
    }

    static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }
}
