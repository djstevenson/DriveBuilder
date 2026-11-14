import Foundation
import SQLite3

/// The YouTube tables: `youtube_videos` (one row per journey final video,
/// see `YouTubeVideo`), `youtube_playlists` (a cache of the channel's
/// playlists), and `youtube_playlist_items` (which videos are in which
/// playlists). Like `chapters`, they're created on first use, so a database
/// from before the YouTube feature just reads as having nothing uploaded.
extension TelemetryStore {
    // MARK: - Videos

    /// A journey's YouTube records, final before fast final. No rows - or
    /// no table yet - just means nothing's been drafted or uploaded.
    func youtubeVideos(journeyID: Int64) throws -> [YouTubeVideo] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        guard try Self.hasTable("youtube_videos", database) else { return [] }

        let sql = """
            SELECT \(Self.videoColumns)
            FROM youtube_videos
            WHERE journey_id = ?
            ORDER BY id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var videos: [YouTubeVideo] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            videos.append(try Self.video(from: statement))
        }
        return videos.sorted { Self.variantOrder($0.variant) < Self.variantOrder($1.variant) }
    }

    /// Saves what the user wants a video's metadata to be: a new draft row
    /// for the variant, or new title, description, and visibility on its
    /// existing row (leaving the upload columns alone). Returns the row as
    /// saved.
    func saveYouTubeVideo(
        journeyID: Int64, variant: YouTubeVideo.Variant, title: String, description: String,
        privacy: YouTubeVideo.Privacy
    ) throws -> YouTubeVideo {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            """
            INSERT INTO youtube_videos (journey_id, variant, title, description, privacy)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (journey_id, variant) DO UPDATE SET
                title = excluded.title,
                description = excluded.description,
                privacy = excluded.privacy
            """
        ) { statement in
            sqlite3_bind_int64(statement, 1, journeyID)
            sqlite3_bind_text(statement, 2, variant.rawValue, -1, Self.transient)
            sqlite3_bind_text(statement, 3, title, -1, Self.transient)
            sqlite3_bind_text(statement, 4, description, -1, Self.transient)
            sqlite3_bind_text(statement, 5, privacy.rawValue, -1, Self.transient)
        }

        guard
            let video = try Self.videos(
                database, where: "journey_id = ? AND variant = ?",
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, journeyID)
                    sqlite3_bind_text(statement, 2, variant.rawValue, -1, Self.transient)
                }
            ).first
        else {
            throw TelemetryStoreError.queryFailed(message: "saved YouTube video not found")
        }
        return video
    }

    /// Records a resumable upload session for the row, so an interrupted
    /// upload of the file modified at `fileModified` can be continued; nil
    /// forgets it.
    func setYouTubeUploadSession(id: Int64, uri: String?, fileModified: Date?) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            "UPDATE youtube_videos SET upload_session_uri = ?, uploaded_file_modified = ? WHERE id = ?"
        ) { statement in
            Self.bind(uri, to: statement, at: 1)
            Self.bind(fileModified, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, id)
        }
    }

    /// Records that the row's movie, modified at `fileModified`, is now on
    /// YouTube as `videoID`. Clears any upload session and marks the
    /// metadata as just synced.
    func markYouTubeVideoUploaded(
        id: Int64, videoID: String, uploadedAt: Date, fileModified: Date?
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            """
            UPDATE youtube_videos
            SET video_id = ?, uploaded_at = ?, uploaded_file_modified = ?,
                upload_session_uri = NULL, synced_at = ?
            WHERE id = ?
            """
        ) { statement in
            sqlite3_bind_text(statement, 1, videoID, -1, Self.transient)
            Self.bind(uploadedAt, to: statement, at: 2)
            Self.bind(fileModified, to: statement, at: 3)
            Self.bind(uploadedAt, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, id)
        }
    }

    /// Rewrites the cached metadata to what YouTube holds (after an edit
    /// it accepted, or a refresh from it), stamped `syncedAt`.
    func updateYouTubeVideo(
        id: Int64, title: String, description: String, privacy: YouTubeVideo.Privacy,
        syncedAt: Date
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            "UPDATE youtube_videos SET title = ?, description = ?, privacy = ?, synced_at = ? WHERE id = ?"
        ) { statement in
            sqlite3_bind_text(statement, 1, title, -1, Self.transient)
            sqlite3_bind_text(statement, 2, description, -1, Self.transient)
            sqlite3_bind_text(statement, 3, privacy.rawValue, -1, Self.transient)
            Self.bind(syncedAt, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, id)
        }
    }

    /// Forgets a video record and its playlist memberships, e.g. after the
    /// video was deleted in YouTube Studio. Nothing on YouTube changes.
    func deleteYouTubeVideo(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(database, "DELETE FROM youtube_playlist_items WHERE youtube_video_id = ?") {
            sqlite3_bind_int64($0, 1, id)
        }
        try Self.run(database, "DELETE FROM youtube_videos WHERE id = ?") {
            sqlite3_bind_int64($0, 1, id)
        }
    }

    // MARK: - Playlists

    /// The cached channel playlists, in the channel's order. Empty until
    /// they've been fetched.
    func youtubePlaylists() throws -> [YouTubePlaylist] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        guard try Self.hasTable("youtube_playlists", database) else { return [] }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT id, title FROM youtube_playlists ORDER BY position, id",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var playlists: [YouTubePlaylist] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            playlists.append(
                YouTubePlaylist(
                    id: Self.string(statement, column: 0) ?? "",
                    title: Self.string(statement, column: 1) ?? ""))
        }
        return playlists
    }

    /// Replaces the cache with the channel's current playlists, in order.
    /// Memberships of playlists no longer listed are dropped too.
    func replaceYouTubePlaylists(_ playlists: [YouTubePlaylist]) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(database, "DELETE FROM youtube_playlists")
            for (position, playlist) in playlists.enumerated() {
                try Self.run(
                    database, "INSERT INTO youtube_playlists (id, title, position) VALUES (?, ?, ?)"
                ) { statement in
                    sqlite3_bind_text(statement, 1, playlist.id, -1, Self.transient)
                    sqlite3_bind_text(statement, 2, playlist.title, -1, Self.transient)
                    sqlite3_bind_int64(statement, 3, Int64(position))
                }
            }
            try execute(
                database,
                """
                DELETE FROM youtube_playlist_items
                WHERE playlist_id NOT IN (SELECT id FROM youtube_playlists)
                """)
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Adds a playlist just created on the channel to the end of the cache.
    func insertYouTubePlaylist(_ playlist: YouTubePlaylist) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            """
            INSERT INTO youtube_playlists (id, title, position)
            VALUES (?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM youtube_playlists))
            ON CONFLICT (id) DO UPDATE SET title = excluded.title
            """
        ) { statement in
            sqlite3_bind_text(statement, 1, playlist.id, -1, Self.transient)
            sqlite3_bind_text(statement, 2, playlist.title, -1, Self.transient)
        }
    }

    // MARK: - Playlist memberships

    /// Which playlists the `youtube_videos` row is in, in playlist order.
    func youtubePlaylistItems(videoRowID: Int64) throws -> [YouTubePlaylistItem] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        guard try Self.hasTable("youtube_playlist_items", database) else { return [] }

        let sql = """
            SELECT i.id, i.youtube_video_id, i.playlist_id
            FROM youtube_playlist_items i
            LEFT JOIN youtube_playlists p ON p.id = i.playlist_id
            WHERE i.youtube_video_id = ?
            ORDER BY p.position, i.id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, videoRowID)

        var items: [YouTubePlaylistItem] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            items.append(
                YouTubePlaylistItem(
                    id: Self.string(statement, column: 0) ?? "",
                    videoRowID: sqlite3_column_int64(statement, 1),
                    playlistID: Self.string(statement, column: 2) ?? ""))
        }
        return items
    }

    /// Records that YouTube added the video to a playlist as `item`.
    func insertYouTubePlaylistItem(_ item: YouTubePlaylistItem) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(
            database,
            """
            INSERT INTO youtube_playlist_items (id, youtube_video_id, playlist_id)
            VALUES (?, ?, ?)
            ON CONFLICT (youtube_video_id, playlist_id) DO UPDATE SET id = excluded.id
            """
        ) { statement in
            sqlite3_bind_text(statement, 1, item.id, -1, Self.transient)
            sqlite3_bind_int64(statement, 2, item.videoRowID)
            sqlite3_bind_text(statement, 3, item.playlistID, -1, Self.transient)
        }
    }

    /// Records that YouTube removed the membership with this playlistItem
    /// id.
    func deleteYouTubePlaylistItem(id: String) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try Self.run(database, "DELETE FROM youtube_playlist_items WHERE id = ?") {
            sqlite3_bind_text($0, 1, id, -1, Self.transient)
        }
    }

    /// Replaces a video's memberships with what YouTube reports.
    func replaceYouTubePlaylistItems(videoRowID: Int64, with items: [YouTubePlaylistItem]) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createYouTubeTablesIfNeeded(database)

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try Self.run(database, "DELETE FROM youtube_playlist_items WHERE youtube_video_id = ?") {
                sqlite3_bind_int64($0, 1, videoRowID)
            }
            for item in items {
                try Self.run(
                    database,
                    "INSERT INTO youtube_playlist_items (id, youtube_video_id, playlist_id) VALUES (?, ?, ?)"
                ) { statement in
                    sqlite3_bind_text(statement, 1, item.id, -1, Self.transient)
                    sqlite3_bind_int64(statement, 2, videoRowID)
                    sqlite3_bind_text(statement, 3, item.playlistID, -1, Self.transient)
                }
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Schema

    /// Whether the database has `table` yet.
    static func hasTable(_ table: String, _ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Creates the YouTube tables on a database from before the feature
    /// existed; a no-op once they're there. Needs a read-write connection.
    func createYouTubeTablesIfNeeded(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS youtube_videos (
                id                     INTEGER PRIMARY KEY,
                journey_id             INTEGER NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                variant                TEXT NOT NULL,   -- 'final' or 'final_fast'
                video_id               TEXT,            -- YouTube's id; NULL until uploaded
                title                  TEXT NOT NULL,
                description            TEXT NOT NULL DEFAULT '',
                privacy                TEXT NOT NULL DEFAULT 'private',
                uploaded_at            TEXT,
                uploaded_file_modified TEXT,            -- the movie file that was uploaded
                upload_session_uri     TEXT,            -- a resumable upload part-way through
                synced_at              TEXT,            -- metadata last confirmed with YouTube
                UNIQUE (journey_id, variant)
            );
            CREATE TABLE IF NOT EXISTS youtube_playlists (
                id       TEXT PRIMARY KEY,   -- YouTube's playlist id
                title    TEXT NOT NULL,
                position INTEGER NOT NULL    -- the channel's order
            );
            CREATE TABLE IF NOT EXISTS youtube_playlist_items (
                id               TEXT PRIMARY KEY,   -- YouTube's playlistItem id
                youtube_video_id INTEGER NOT NULL REFERENCES youtube_videos(id) ON DELETE CASCADE,
                playlist_id      TEXT NOT NULL,
                UNIQUE (youtube_video_id, playlist_id)
            )
            """)
    }

    // MARK: - Helpers

    private static let videoColumns = """
        id, journey_id, variant, video_id, title, description, privacy,
        uploaded_at, uploaded_file_modified, upload_session_uri, synced_at
        """

    private static func videos(
        _ database: OpaquePointer?, where condition: String, bind: (OpaquePointer?) -> Void
    ) throws -> [YouTubeVideo] {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT \(videoColumns) FROM youtube_videos WHERE \(condition)",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        var videos: [YouTubeVideo] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: lastErrorMessage(database))
            }
            videos.append(try video(from: statement))
        }
        return videos
    }

    private static func video(from statement: OpaquePointer?) throws -> YouTubeVideo {
        YouTubeVideo(
            id: sqlite3_column_int64(statement, 0),
            journeyID: sqlite3_column_int64(statement, 1),
            variant: YouTubeVideo.Variant(rawValue: string(statement, column: 2) ?? "") ?? .final,
            videoID: string(statement, column: 3),
            title: string(statement, column: 4) ?? "",
            description: string(statement, column: 5) ?? "",
            privacy: YouTubeVideo.Privacy(rawValue: string(statement, column: 6) ?? "") ?? .private,
            uploadedAt: try date(statement, column: 7),
            uploadedFileModified: try date(statement, column: 8),
            uploadSessionURI: string(statement, column: 9),
            syncedAt: try date(statement, column: 10))
    }

    private static func variantOrder(_ variant: YouTubeVideo.Variant) -> Int {
        YouTubeVideo.Variant.allCases.firstIndex(of: variant) ?? 0
    }

    /// Prepares `sql`, lets `bind` fill its parameters, and steps it to
    /// completion.
    private static func run(
        _ database: OpaquePointer?, _ sql: String, bind: (OpaquePointer?) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: lastErrorMessage(database))
        }
    }

    /// Binds an optional string, NULL for nil.
    private static func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    /// Binds a date in the database's timestamp format, NULL for nil.
    private static func bind(_ value: Date?, to statement: OpaquePointer?, at index: Int32) {
        bind(value.map { $0.formatted(timestampStrategy) }, to: statement, at: index)
    }
}
