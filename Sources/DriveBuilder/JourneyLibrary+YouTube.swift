import Foundation

/// The YouTube records a front end reads and writes: see `YouTubeVideo`.
/// Every method is `@concurrent` for the same reason as `journeys()`: keep
/// the database access off the caller's (GUI main) actor.
extension JourneyLibrary {
    /// A journey's YouTube records, final before fast final; empty when
    /// nothing's been drafted or uploaded.
    @concurrent
    package func youtubeVideos(journeyID: Int64) async throws -> [YouTubeVideo] {
        try TelemetryStore(path: databasePath).youtubeVideos(journeyID: journeyID)
    }

    /// Saves the wanted title, description, and visibility for one of the
    /// journey's final videos, creating its draft row if needed, and
    /// returns the row.
    @concurrent
    package func saveYouTubeVideo(
        journeyID: Int64, variant: YouTubeVideo.Variant, title: String, description: String,
        privacy: YouTubeVideo.Privacy
    ) async throws -> YouTubeVideo {
        try TelemetryStore(path: databasePath).saveYouTubeVideo(
            journeyID: journeyID, variant: variant, title: title, description: description,
            privacy: privacy)
    }

    /// Records (or with nil, forgets) a resumable upload session for the
    /// row, for the file modified at `fileModified`.
    @concurrent
    package func setYouTubeUploadSession(id: Int64, uri: String?, fileModified: Date?) async throws {
        try TelemetryStore(path: databasePath).setYouTubeUploadSession(
            id: id, uri: uri, fileModified: fileModified)
    }

    /// Records that the row's movie is now on YouTube as `videoID`.
    @concurrent
    package func markYouTubeVideoUploaded(
        id: Int64, videoID: String, uploadedAt: Date, fileModified: Date?
    ) async throws {
        try TelemetryStore(path: databasePath).markYouTubeVideoUploaded(
            id: id, videoID: videoID, uploadedAt: uploadedAt, fileModified: fileModified)
    }

    /// Rewrites the cached metadata to what YouTube now holds.
    @concurrent
    package func updateYouTubeVideo(
        id: Int64, title: String, description: String, privacy: YouTubeVideo.Privacy,
        syncedAt: Date
    ) async throws {
        try TelemetryStore(path: databasePath).updateYouTubeVideo(
            id: id, title: title, description: description, privacy: privacy, syncedAt: syncedAt)
    }

    /// Forgets a video record and its memberships; YouTube is untouched.
    @concurrent
    package func deleteYouTubeVideo(id: Int64) async throws {
        try TelemetryStore(path: databasePath).deleteYouTubeVideo(id: id)
    }

    /// The cached channel playlists, in the channel's order.
    @concurrent
    package func youtubePlaylists() async throws -> [YouTubePlaylist] {
        try TelemetryStore(path: databasePath).youtubePlaylists()
    }

    /// Replaces the playlist cache with the channel's current list.
    @concurrent
    package func replaceYouTubePlaylists(_ playlists: [YouTubePlaylist]) async throws {
        try TelemetryStore(path: databasePath).replaceYouTubePlaylists(playlists)
    }

    /// Adds a newly created playlist to the cache.
    @concurrent
    package func insertYouTubePlaylist(_ playlist: YouTubePlaylist) async throws {
        try TelemetryStore(path: databasePath).insertYouTubePlaylist(playlist)
    }

    /// Which playlists a `youtube_videos` row is in.
    @concurrent
    package func youtubePlaylistItems(videoRowID: Int64) async throws -> [YouTubePlaylistItem] {
        try TelemetryStore(path: databasePath).youtubePlaylistItems(videoRowID: videoRowID)
    }

    /// Records a membership YouTube just created.
    @concurrent
    package func insertYouTubePlaylistItem(_ item: YouTubePlaylistItem) async throws {
        try TelemetryStore(path: databasePath).insertYouTubePlaylistItem(item)
    }

    /// Records a membership YouTube just removed.
    @concurrent
    package func deleteYouTubePlaylistItem(id: String) async throws {
        try TelemetryStore(path: databasePath).deleteYouTubePlaylistItem(id: id)
    }

    /// Replaces a video's memberships with what YouTube reports.
    @concurrent
    package func replaceYouTubePlaylistItems(
        videoRowID: Int64, with items: [YouTubePlaylistItem]
    ) async throws {
        try TelemetryStore(path: databasePath).replaceYouTubePlaylistItems(
            videoRowID: videoRowID, with: items)
    }
}
