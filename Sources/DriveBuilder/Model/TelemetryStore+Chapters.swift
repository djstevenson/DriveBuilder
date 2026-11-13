import Foundation
import SQLite3

/// The `chapters` table: a journey's own chapter markers for the final
/// videos (see `Chapter`). Unlike the older tables it's created on first
/// use rather than by a migration, so a database from before chapters
/// existed just reads as having none.
extension TelemetryStore {
    /// A journey's chapter markers, in the order they were added (when each
    /// starts depends on the track, not the row). No rows - or no table yet
    /// - just means none have been authored.
    func chapters(journeyID: Int64) throws -> [Chapter] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        guard try Self.hasChaptersTable(database) else { return [] }

        let sql = """
            SELECT id, journey_id, title, latitude, longitude
            FROM chapters
            WHERE journey_id = ?
            ORDER BY id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var chapters: [Chapter] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            chapters.append(
                Chapter(
                    id: sqlite3_column_int64(statement, 0),
                    journeyID: sqlite3_column_int64(statement, 1),
                    title: Self.string(statement, column: 2) ?? "",
                    location: Self.location(statement, column: 3)))
        }
        return chapters
    }

    /// Inserts one chapter marker for `journeyID`.
    func insertChapter(journeyID: Int64, title: String, location: TrackLocation) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createChaptersTableIfNeeded(database)

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "INSERT INTO chapters (journey_id, title, latitude, longitude) VALUES (?, ?, ?, ?)",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        sqlite3_bind_text(statement, 2, title, -1, Self.transient)
        Self.bind(location, to: statement, at: 3)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Rewrites one chapter marker's fields.
    func updateChapter(id: Int64, title: String, location: TrackLocation) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createChaptersTableIfNeeded(database)

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "UPDATE chapters SET title = ?, latitude = ?, longitude = ? WHERE id = ?",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, title, -1, Self.transient)
        Self.bind(location, to: statement, at: 2)
        sqlite3_bind_int64(statement, 4, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Removes one chapter marker.
    func deleteChapter(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try createChaptersTableIfNeeded(database)

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "DELETE FROM chapters WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Whether the database has a `chapters` table yet.
    static func hasChaptersTable(_ database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chapters'",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Creates the `chapters` table on a database from before chapters
    /// existed; a no-op once it's there. Needs a read-write connection.
    func createChaptersTableIfNeeded(_ database: OpaquePointer?) throws {
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS chapters (
                id         INTEGER PRIMARY KEY,
                journey_id INTEGER NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                title      TEXT NOT NULL,
                latitude   REAL NOT NULL,   -- where the chapter starts
                longitude  REAL NOT NULL
            )
            """)
    }
}
