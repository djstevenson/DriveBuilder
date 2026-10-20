import Foundation
import SQLite3

/// The one-off move of each journey's synchronisation offsets and length
/// from its `journeys` row into a `journey_segments` table, as the journey's
/// single segment over the default files (front.mov, rear.mov, left.mov,
/// right.mov). Nothing is converted, just moved, so there's no plan stage.
extension TelemetryStore {
    /// The `journeys` columns that move into the journey's first segment.
    private static let segmentColumns = [
        "front_offset", "rear_offset", "telemetry_offset", "left_offset", "right_offset",
        "length",
    ]

    /// Whether the database still keeps the offsets on the `journeys` row.
    func needsSegmentMigration() throws -> Bool {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }
        let columns = try query(database, "PRAGMA table_info(journeys)") {
            Self.string($0, column: 1) ?? ""
        }
        return columns.contains("front_offset")
    }

    /// Copies the database to `backupPath` (which mustn't exist yet), then
    /// creates `journey_segments`, gives every journey one segment holding
    /// its offsets and length, and drops those columns from `journeys` - all
    /// or nothing. Returns how many journeys were migrated.
    @discardableResult
    func applySegmentMigration(backupPath: String) throws -> Int {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        try backUp(database, to: backupPath)

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                """
                CREATE TABLE journey_segments (
                    id               INTEGER PRIMARY KEY,
                    journey_id       INTEGER NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                    position         INTEGER NOT NULL,   -- playback order, from 0
                    front_file       TEXT NOT NULL DEFAULT 'front.mov',   -- beneath video/
                    rear_file        TEXT NOT NULL DEFAULT 'rear.mov',
                    left_file        TEXT NOT NULL DEFAULT 'left.mov',
                    right_file       TEXT NOT NULL DEFAULT 'right.mov',
                    front_offset     REAL NOT NULL DEFAULT 0.0,
                    rear_offset      REAL NOT NULL DEFAULT 0.0,
                    telemetry_offset REAL NOT NULL DEFAULT 0.0,   -- from the first sample
                    left_offset      REAL DEFAULT NULL,   -- NULL = no such view
                    right_offset     REAL DEFAULT NULL,
                    length           REAL DEFAULT NULL,   -- NULL = shortest source
                    UNIQUE (journey_id, position)
                );
                INSERT INTO journey_segments
                    (journey_id, position, front_offset, rear_offset, telemetry_offset,
                    left_offset, right_offset, length)
                SELECT id, 0, front_offset, rear_offset, telemetry_offset,
                    left_offset, right_offset, length
                FROM journeys;
                """)
            let migrated = Int(sqlite3_changes(database))
            for column in Self.segmentColumns {
                try execute(database, "ALTER TABLE journeys DROP COLUMN \(column)")
            }
            try execute(database, "COMMIT")
            return migrated
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }
}
