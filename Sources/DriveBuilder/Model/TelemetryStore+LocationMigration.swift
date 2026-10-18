import Foundation
import SQLite3

/// One stored time the one-off migration to locations converts: an
/// annotation's end, a camera override's start or end, or a route-map
/// label's reveal.
struct LocationMigrationItem: Sendable {
    enum Table: String, Sendable {
        case annotations
        case cameraOverrides = "camera_overrides"
        case routeMapLabels = "route_map_labels"
    }

    enum Field: String, Sendable {
        case start, end, reveal
    }

    let table: Table
    let id: Int64
    let journeyID: Int64
    /// The row as David knows it: the annotation's video, the override's
    /// camera, or the label's title.
    let name: String
    let field: Field
    /// The time as stored: raw front.mov seconds for annotations and
    /// overrides, raw telemetry seconds for labels.
    let storedSeconds: Double
    /// The same moment as seconds since the journey's first sample.
    let telemetrySeconds: Double
    /// Where the track was then; nil if it couldn't be converted.
    var location: TrackLocation?
    /// How far the location's own time (found by `TrackLocator`, as
    /// renders will) lands from `telemetrySeconds`.
    var driftSeconds: Double?
    /// Why the item can't be migrated safely, if it can't.
    var problem: String?
}

/// The one-off move of annotations, camera overrides, and route-map labels
/// from time offsets to locations: plan (convert and check every item,
/// changing nothing), then apply (back up, then rebuild the three tables in
/// one transaction).
extension TelemetryStore {
    /// The most a converted item may drift when its location is turned back
    /// into a time; more suggests a point passed twice or a stop.
    static let maximumMigrationDriftSeconds = 0.5

    /// Whether the database still has the old time-offset columns.
    func hasTimeOffsetColumns() throws -> Bool {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }
        let columns = try query(database, "PRAGMA table_info(annotations)") {
            Self.string($0, column: 1) ?? ""
        }
        return columns.contains("offset")
    }

    /// Converts every stored time to a location and checks each converts
    /// back, without changing anything.
    func planLocationMigration() throws -> [LocationMigrationItem] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        // (table, id, journey, name, field, stored seconds, front-based?)
        typealias Row = (
            LocationMigrationItem.Table, Int64, Int64, String, LocationMigrationItem.Field,
            Double, Bool
        )
        var rows: [Row] = []
        rows += try query(
            database, "SELECT id, journey_id, video, \"offset\" FROM annotations ORDER BY id"
        ) {
            (
                .annotations, sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1),
                Self.string($0, column: 2) ?? "", .end, sqlite3_column_double($0, 3), true
            )
        }
        for override in try query(
            database,
            "SELECT id, journey_id, camera, start_offset, end_offset FROM camera_overrides ORDER BY id",
            { statement -> (Int64, Int64, String, Double, Double) in
                (
                    sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1),
                    Self.string(statement, column: 2) ?? "", sqlite3_column_double(statement, 3),
                    sqlite3_column_double(statement, 4)
                )
            })
        {
            rows.append((.cameraOverrides, override.0, override.1, override.2, .start, override.3, true))
            rows.append((.cameraOverrides, override.0, override.1, override.2, .end, override.4, true))
        }
        rows += try query(
            database, "SELECT id, journey_id, title, \"offset\" FROM route_map_labels ORDER BY id"
        ) {
            (
                .routeMapLabels, sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1),
                Self.string($0, column: 2) ?? "", .reveal, sqlite3_column_double($0, 3), false
            )
        }

        var locators: [Int64: TrackLocator?] = [:]
        return try rows.map { table, id, journeyID, name, field, stored, isFrontBased in
            let offsets = try journeyStartOffsets(journeyID: journeyID) ?? StartOffsets()
            let telemetrySeconds =
                isFrontBased ? stored - offsets.front + offsets.telemetry : stored
            var item = LocationMigrationItem(
                table: table, id: id, journeyID: journeyID, name: name, field: field,
                storedSeconds: stored, telemetrySeconds: telemetrySeconds)

            if locators[journeyID] == nil {
                locators[journeyID] = (try? records(journeyID: journeyID)).map {
                    TrackLocator(records: $0)
                }
            }
            guard let locator = locators[journeyID] ?? nil else {
                item.problem = "journey \(journeyID) has no telemetry"
                return item
            }
            guard let location = locator.location(atTelemetrySeconds: telemetrySeconds) else {
                item.problem =
                    "telemetry \(ClockTime.text(for: telemetrySeconds)) is outside the recorded track"
                return item
            }
            item.location = location
            do {
                let fix = try locator.locate(location)
                let drift = fix.telemetrySeconds - telemetrySeconds
                item.driftSeconds = drift
                if abs(drift) > Self.maximumMigrationDriftSeconds {
                    item.problem = String(
                        format: "its location converts back %.1fs away (stopped there, or "
                            + "passed it twice?)", drift)
                }
            } catch {
                item.problem = String(describing: error)
            }
            return item
        }
    }

    /// Copies the database to `backupPath` (which mustn't exist yet), then
    /// rebuilds the three tables with location columns in place of time
    /// offsets, filled from `items` - all or nothing. Throws, changing
    /// nothing, if any item has a problem or a row has no item.
    func applyLocationMigration(_ items: [LocationMigrationItem], backupPath: String) throws {
        if let bad = items.first(where: { $0.problem != nil || $0.location == nil }) {
            throw TelemetryStoreError.queryFailed(
                message: "\(bad.table.rawValue) \(bad.id) (\(bad.name)) can't be migrated: "
                    + (bad.problem ?? "no location"))
        }
        var locations: [String: TrackLocation] = [:]
        for item in items {
            locations["\(item.table.rawValue)/\(item.id)/\(item.field.rawValue)"] = item.location
        }
        func location(
            _ table: LocationMigrationItem.Table, _ id: Int64, _ field: LocationMigrationItem.Field
        ) throws -> TrackLocation {
            guard let location = locations["\(table.rawValue)/\(id)/\(field.rawValue)"] else {
                throw TelemetryStoreError.queryFailed(
                    message: "\(table.rawValue) \(id) has no \(field.rawValue) location to migrate")
            }
            return location
        }

        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var backup: OpaquePointer?
        guard sqlite3_prepare_v2(database, "VACUUM INTO ?", -1, &backup, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        sqlite3_bind_text(backup, 1, backupPath, -1, Self.transient)
        let backedUp = sqlite3_step(backup)
        sqlite3_finalize(backup)
        guard backedUp == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(
                message: "Could not back up to \(backupPath): \(Self.lastErrorMessage(database))")
        }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            try execute(
                database,
                """
                CREATE TABLE annotations_new (
                    id         INTEGER NOT NULL PRIMARY KEY,
                    journey_id INTEGER NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                    video      TEXT NOT NULL,
                    text       TEXT NOT NULL,
                    latitude   REAL NOT NULL,   -- where the banner finishes
                    longitude  REAL NOT NULL,
                    UNIQUE (journey_id, video)
                );
                CREATE TABLE camera_overrides_new (
                    id              INTEGER PRIMARY KEY,
                    journey_id      INTEGER NOT NULL REFERENCES journeys(id) ON DELETE CASCADE,
                    camera          TEXT NOT NULL CHECK (camera IN ('rear', 'left', 'right')),
                    start_latitude  REAL NOT NULL,   -- where the window opens
                    start_longitude REAL NOT NULL,
                    end_latitude    REAL NOT NULL,   -- where it closes
                    end_longitude   REAL NOT NULL,
                    label           TEXT             -- NULL = the camera's default label
                );
                CREATE TABLE route_map_labels_new (
                    id         INTEGER PRIMARY KEY,
                    journey_id INTEGER NOT NULL REFERENCES journeys(id),
                    latitude   REAL NOT NULL,            -- where the track reveals it
                    longitude  REAL NOT NULL,
                    title      TEXT NOT NULL,
                    subtitle   TEXT NOT NULL DEFAULT '',
                    location   TEXT NOT NULL DEFAULT 'right',   -- side of the track
                    distance   REAL                      -- NULL = renderer default
                );
                """)

            for id in try query(database, "SELECT id FROM annotations", { sqlite3_column_int64($0, 0) }) {
                try copyRow(
                    database,
                    """
                    INSERT INTO annotations_new (id, journey_id, video, text, latitude, longitude)
                    SELECT id, journey_id, video, text, ?, ? FROM annotations WHERE id = ?
                    """,
                    locations: [try location(.annotations, id, .end)], id: id)
            }
            for id in try query(database, "SELECT id FROM camera_overrides", { sqlite3_column_int64($0, 0) }) {
                try copyRow(
                    database,
                    """
                    INSERT INTO camera_overrides_new
                        (id, journey_id, camera, start_latitude, start_longitude,
                        end_latitude, end_longitude, label)
                    SELECT id, journey_id, camera, ?, ?, ?, ?, label
                    FROM camera_overrides WHERE id = ?
                    """,
                    locations: [
                        try location(.cameraOverrides, id, .start),
                        try location(.cameraOverrides, id, .end),
                    ],
                    id: id)
            }
            for id in try query(database, "SELECT id FROM route_map_labels", { sqlite3_column_int64($0, 0) }) {
                try copyRow(
                    database,
                    """
                    INSERT INTO route_map_labels_new
                        (id, journey_id, latitude, longitude, title, subtitle, location, distance)
                    SELECT id, journey_id, ?, ?, title, subtitle, location, distance
                    FROM route_map_labels WHERE id = ?
                    """,
                    locations: [try location(.routeMapLabels, id, .reveal)], id: id)
            }

            for table in ["annotations", "camera_overrides", "route_map_labels"] {
                try execute(database, "DROP TABLE \(table)")
                try execute(database, "ALTER TABLE \(table)_new RENAME TO \(table)")
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Runs one row-copying insert whose parameters are `locations` (two
    /// each) followed by the row `id`.
    private func copyRow(
        _ database: OpaquePointer?, _ sql: String, locations: [TrackLocation], id: Int64
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        for (index, location) in locations.enumerated() {
            Self.bind(location, to: statement, at: Int32(index * 2 + 1))
        }
        sqlite3_bind_int64(statement, Int32(locations.count * 2 + 1), id)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw TelemetryStoreError.queryFailed(
                message: "Could not copy row \(id): \(Self.lastErrorMessage(database))")
        }
    }

    /// Every row `sql` returns, each read by `row`.
    private func query<T>(
        _ database: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            rows.append(row(statement))
        }
        return rows
    }
}
