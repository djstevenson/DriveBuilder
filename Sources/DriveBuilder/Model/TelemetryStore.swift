import Foundation
import SQLite3

enum TelemetryStoreError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case queryFailed(message: String)
    case unparsableTimestamp(String)
    case journeyNotFound(journeyID: Int64)
    case telemetryNotFound(journeyID: Int64)
    case duplicateAnnotation(video: String)
    case duplicateJourney(source: String)

    var description: String {
        switch self {
        case .openFailed(let path, let message):
            "Could not open telemetry database at \(path): \(message)"
        case .queryFailed(let message):
            "Telemetry query failed: \(message)"
        case .unparsableTimestamp(let value):
            "Could not parse telemetry timestamp \"\(value)\""
        case .journeyNotFound(let journeyID):
            "Journey not found: no journey with id \(journeyID)"
        case .telemetryNotFound(let journeyID):
            "Telemetry not found: journey \(journeyID) exists but has no telemetry data"
        case .duplicateAnnotation(let video):
            "An annotation named \"\(video)\" already exists for this journey"
        case .duplicateJourney(let source):
            "A journey with source directory \"\(source)\" already exists"
        }
    }
}

/// Access to the telemetry SQLite database: the render subcommands read
/// journeys from it, and the telemetry subcommand inserts them.
struct TelemetryStore {
    let path: String

    /// Timestamps are stored without a zone designator, e.g. "2026-07-26T14:37:55.100", and are UTC.
    private static let timestampStrategy = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day()
        .dateTimeSeparator(.standard)
        .time(includingFractionalSeconds: true)

    /// Every telemetry sample belonging to `journeyID`, in timestamp order.
    func records(journeyID: Int64) throws -> [TelemetryRecord] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        guard try Self.journeyExists(journeyID: journeyID, database: database) else {
            throw TelemetryStoreError.journeyNotFound(journeyID: journeyID)
        }

        let sql = """
            SELECT id, journey_id, timestamp, latitude, longitude, altitude, speed, heading,
                   accel_forward, accel_lateral, speed_limit, file, source, odometer
            FROM telemetry
            WHERE journey_id = ?
            ORDER BY timestamp
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var records: [TelemetryRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            records.append(try Self.record(from: statement))
        }

        guard !records.isEmpty else {
            throw TelemetryStoreError.telemetryNotFound(journeyID: journeyID)
        }
        return records
    }

    /// Every annotation banner for `journeyID`, in the order they were
    /// added (when each ends depends on the track, not the row). No rows
    /// just means none have been authored yet, not an error.
    func annotations(journeyID: Int64) throws -> [Annotation] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, journey_id, video, text, latitude, longitude
            FROM annotations
            WHERE journey_id = ?
            ORDER BY id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var annotations: [Annotation] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            annotations.append(
                Annotation(
                    id: sqlite3_column_int64(statement, 0),
                    journeyID: sqlite3_column_int64(statement, 1),
                    video: Self.string(statement, column: 2) ?? "",
                    text: Self.string(statement, column: 3) ?? "",
                    endLocation: Self.location(statement, column: 4)))
        }
        return annotations
    }

    /// A journey's route-map labels, in the order they were added. No rows
    /// just means none have been authored yet.
    func routeMapLabels(journeyID: Int64) throws -> [RouteMapLabel] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, journey_id, latitude, longitude, title, subtitle, location, distance
            FROM route_map_labels
            WHERE journey_id = ?
            ORDER BY id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var labels: [RouteMapLabel] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            labels.append(
                RouteMapLabel(
                    id: sqlite3_column_int64(statement, 0),
                    journeyID: sqlite3_column_int64(statement, 1),
                    revealLocation: Self.location(statement, column: 2),
                    title: Self.string(statement, column: 4) ?? "",
                    subtitle: Self.string(statement, column: 5) ?? "",
                    location: RouteMapLabel.Location(
                        rawValue: Self.string(statement, column: 6) ?? "") ?? .right,
                    distance: Self.double(statement, column: 7)))
        }
        return labels
    }

    /// Inserts one route-map label for `journeyID`. A nil `distance` is
    /// stored as NULL, meaning the renderer's default gap.
    func insertRouteMapLabel(
        journeyID: Int64, revealLocation: TrackLocation, title: String, subtitle: String,
        location: RouteMapLabel.Location, distance: Double?
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                """
                INSERT INTO route_map_labels
                    (journey_id, latitude, longitude, title, subtitle, location, distance)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        Self.bind(revealLocation, to: statement, at: 2)
        sqlite3_bind_text(statement, 4, title, -1, Self.transient)
        sqlite3_bind_text(statement, 5, subtitle, -1, Self.transient)
        sqlite3_bind_text(statement, 6, location.rawValue, -1, Self.transient)
        if let distance {
            sqlite3_bind_double(statement, 7, distance)
        } else {
            sqlite3_bind_null(statement, 7)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Rewrites one route-map label's fields.
    func updateRouteMapLabel(
        id: Int64, revealLocation: TrackLocation, title: String, subtitle: String,
        location: RouteMapLabel.Location, distance: Double?
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                """
                UPDATE route_map_labels
                SET latitude = ?, longitude = ?, title = ?, subtitle = ?, location = ?,
                    distance = ?
                WHERE id = ?
                """,
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        Self.bind(revealLocation, to: statement, at: 1)
        sqlite3_bind_text(statement, 3, title, -1, Self.transient)
        sqlite3_bind_text(statement, 4, subtitle, -1, Self.transient)
        sqlite3_bind_text(statement, 5, location.rawValue, -1, Self.transient)
        if let distance {
            sqlite3_bind_double(statement, 6, distance)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int64(statement, 7, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Removes one route-map label.
    func deleteRouteMapLabel(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "DELETE FROM route_map_labels WHERE id = ?", -1, &statement, nil)
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

    /// A journey's camera-slot overrides, in the order they were added. No
    /// rows just means the slot shows the rear view throughout.
    func cameraOverrides(journeyID: Int64) throws -> [CameraOverride] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, journey_id, camera, start_latitude, start_longitude,
                end_latitude, end_longitude, label
            FROM camera_overrides
            WHERE journey_id = ?
            ORDER BY id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var overrides: [CameraOverride] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            // The column's CHECK constraint keeps it to known cameras.
            guard
                let camera = CameraOverride.Camera(
                    rawValue: Self.string(statement, column: 2) ?? "")
            else { continue }
            overrides.append(
                CameraOverride(
                    id: sqlite3_column_int64(statement, 0),
                    journeyID: sqlite3_column_int64(statement, 1),
                    camera: camera,
                    startLocation: Self.location(statement, column: 3),
                    endLocation: Self.location(statement, column: 5),
                    label: Self.string(statement, column: 7)))
        }
        return overrides
    }

    /// Inserts one camera-slot override for `journeyID`. A nil `label` is
    /// stored as NULL, meaning the camera's default label.
    func insertCameraOverride(
        journeyID: Int64, camera: CameraOverride.Camera, start: TrackLocation,
        end: TrackLocation, label: String?
    ) throws {
        try writeCameraOverride(
            sql: """
                INSERT INTO camera_overrides
                    (camera, start_latitude, start_longitude, end_latitude, end_longitude,
                    label, journey_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            camera: camera, start: start, end: end, label: label, key: journeyID)
    }

    /// Rewrites one camera-slot override's fields.
    func updateCameraOverride(
        id: Int64, camera: CameraOverride.Camera, start: TrackLocation, end: TrackLocation,
        label: String?
    ) throws {
        try writeCameraOverride(
            sql: """
                UPDATE camera_overrides
                SET camera = ?, start_latitude = ?, start_longitude = ?, end_latitude = ?,
                    end_longitude = ?, label = ?
                WHERE id = ?
                """,
            camera: camera, start: start, end: end, label: label, key: id)
    }

    /// Runs an insert or update whose parameters are the override's fields
    /// followed by `key` (the journey id or the row id).
    private func writeCameraOverride(
        sql: String, camera: CameraOverride.Camera, start: TrackLocation, end: TrackLocation,
        label: String?, key: Int64
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, camera.rawValue, -1, Self.transient)
        Self.bind(start, to: statement, at: 2)
        Self.bind(end, to: statement, at: 4)
        if let label {
            sqlite3_bind_text(statement, 6, label, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int64(statement, 7, key)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Removes one camera-slot override.
    func deleteCameraOverride(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "DELETE FROM camera_overrides WHERE id = ?", -1, &statement, nil)
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

    /// Inserts one annotation banner for `journeyID`. `video` must be
    /// unique within the journey — it names the output movie — so a
    /// duplicate throws `duplicateAnnotation` rather than a raw SQLite
    /// constraint message.
    func insertAnnotation(
        journeyID: Int64, video: String, text: String, endLocation: TrackLocation
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                """
                INSERT INTO annotations (journey_id, video, text, latitude, longitude)
                VALUES (?, ?, ?, ?, ?)
                """,
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        sqlite3_bind_text(statement, 2, video, -1, Self.transient)
        sqlite3_bind_text(statement, 3, text, -1, Self.transient)
        Self.bind(endLocation, to: statement, at: 4)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            // The only constraint reachable here is UNIQUE (journey_id,
            // video): every column is bound, and foreign keys aren't
            // enforced without PRAGMA foreign_keys.
            if result == SQLITE_CONSTRAINT {
                throw TelemetryStoreError.duplicateAnnotation(video: video)
            }
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Rewrites one annotation's fields. Like inserting, the new `video`
    /// must stay unique within the journey, so a clash throws
    /// `duplicateAnnotation`.
    func updateAnnotation(
        id: Int64, video: String, text: String, endLocation: TrackLocation
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                """
                UPDATE annotations SET video = ?, text = ?, latitude = ?, longitude = ?
                WHERE id = ?
                """,
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, video, -1, Self.transient)
        sqlite3_bind_text(statement, 2, text, -1, Self.transient)
        Self.bind(endLocation, to: statement, at: 3)
        sqlite3_bind_int64(statement, 5, id)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_CONSTRAINT {
                throw TelemetryStoreError.duplicateAnnotation(video: video)
            }
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Removes one annotation. The rendered movie, if any, stays on disk.
    func deleteAnnotation(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "DELETE FROM annotations WHERE id = ?", -1, &statement, nil)
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

    private static func journeyExists(journeyID: Int64, database: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "SELECT 1 FROM journeys WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Opens the database read-only, binds `journeyID` to `sql`'s single
    /// placeholder, and hands the first result row to `read`; nil if there
    /// is no such journey (or `read` itself returns nil).
    private func fetchJourneyRow<T>(
        journeyID: Int64, sql: String, read: (OpaquePointer?) -> T?
    ) throws -> T? {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return read(statement)
    }

    /// The journey's directory, where its source footage, annotations, and
    /// output live, as recorded by the capture pipeline in `journeys.source`.
    func journeyDirectory(journeyID: Int64) throws -> String? {
        try fetchJourneyRow(
            journeyID: journeyID, sql: "SELECT source FROM journeys WHERE id = ?"
        ) {
            Self.string($0, column: 0)
        }
    }

    /// The journey's title, as recorded by the capture pipeline in
    /// `journeys.title`.
    func journeyTitle(journeyID: Int64) throws -> String? {
        try fetchJourneyRow(
            journeyID: journeyID, sql: "SELECT title FROM journeys WHERE id = ?"
        ) {
            Self.string($0, column: 0)
        }
    }

    /// The journey's segments, in playback order; empty if it has none.
    func journeySegments(journeyID: Int64) throws -> [JourneySegment] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, journey_id, position, front_file, rear_file, left_file, right_file,
                   front_offset, rear_offset, telemetry_offset, left_offset, right_offset,
                   length
            FROM journey_segments
            WHERE journey_id = ?
            ORDER BY position
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)

        var segments: [JourneySegment] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            segments.append(
                JourneySegment(
                    id: sqlite3_column_int64(statement, 0),
                    journeyID: sqlite3_column_int64(statement, 1),
                    position: Self.integer(statement, column: 2) ?? 0,
                    frontFile: Self.string(statement, column: 3) ?? "",
                    rearFile: Self.string(statement, column: 4) ?? "",
                    leftFile: Self.string(statement, column: 5) ?? "",
                    rightFile: Self.string(statement, column: 6) ?? "",
                    startOffsets: Self.startOffsets(statement, column: 7),
                    length: Self.double(statement, column: 12)))
        }
        return segments
    }

    /// The journey's first segment's synchronisation offsets (see
    /// `JourneySegment`), for the one-off location migration, which ran
    /// when every journey had just the one. Nil if the journey has no
    /// segment.
    func journeyStartOffsets(journeyID: Int64) throws -> StartOffsets? {
        try fetchJourneyRow(
            journeyID: journeyID,
            sql: """
                SELECT front_offset, rear_offset, telemetry_offset, left_offset, right_offset
                FROM journey_segments WHERE journey_id = ? AND position = 0
                """
        ) { statement in
            Self.startOffsets(statement, column: 0)
        }
    }

    /// The journey's road, as recorded by the capture pipeline in
    /// `journeys.road_type`/`journeys.road_number`, e.g. ("A", 338); nil if
    /// either column is missing, rather than letting SQLite's NULL-as-zero
    /// read produce a road like "A0".
    func journeyRoad(journeyID: Int64) throws -> (type: String, number: Int)? {
        try fetchJourneyRow(
            journeyID: journeyID,
            sql: "SELECT road_type, road_number FROM journeys WHERE id = ?"
        ) { statement in
            guard
                let type = Self.string(statement, column: 0),
                let number = Self.integer(statement, column: 1)
            else { return nil }
            return (type: type, number: number)
        }
    }

    /// A summary of every journey with its telemetry aggregates, newest
    /// first. Journeys with no telemetry still appear, with a zero sample
    /// count and nil timestamps.
    func allJourneys() throws -> [JourneySummary] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT j.id, j.title, j.road_type, j.road_number, j.source,
                   COUNT(t.id), MIN(t.timestamp), MAX(t.timestamp),
                   MAX(t.odometer) - MIN(t.odometer)
            FROM journeys j
            LEFT JOIN telemetry t ON t.journey_id = j.id
            GROUP BY j.id
            ORDER BY j.id DESC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var journeys: [JourneySummary] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            journeys.append(
                JourneySummary(
                    id: sqlite3_column_int64(statement, 0),
                    title: Self.string(statement, column: 1) ?? "",
                    roadType: Self.string(statement, column: 2) ?? "",
                    roadNumber: Self.integer(statement, column: 3) ?? 0,
                    directory: Self.string(statement, column: 4) ?? "",
                    sampleCount: Self.integer(statement, column: 5) ?? 0,
                    start: try Self.date(statement, column: 6),
                    end: try Self.date(statement, column: 7),
                    distanceMetres: Self.double(statement, column: 8) ?? 0))
        }
        return journeys
    }

    private static func date(_ statement: OpaquePointer?, column: Int32) throws -> Date? {
        guard let raw = string(statement, column: column) else { return nil }
        guard let date = try? Date(raw, strategy: timestampStrategy) else {
            throw TelemetryStoreError.unparsableTimestamp(raw)
        }
        return date
    }

    // MARK: - Segments

    /// Adds a segment after the journey's last, returning it. Its sources
    /// start as guesses for the usual break: a new front file, the same rear
    /// file and telemetry picking up where the last segment ends (the
    /// dashcam usually keeps running), and no side cameras.
    func insertSegment(journeyID: Int64) throws -> JourneySegment {
        guard let last = try journeySegments(journeyID: journeyID).last else {
            throw TelemetryStoreError.queryFailed(
                message: "Journey \(journeyID) has no segment to follow.")
        }
        let position = last.position + 1
        let carriedOn = last.length ?? 0
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try run(
            database,
            """
            INSERT INTO journey_segments
                (journey_id, position, front_file, rear_file, left_file, right_file,
                rear_offset, telemetry_offset)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            sqlite3_bind_int64(statement, 1, journeyID)
            sqlite3_bind_int64(statement, 2, Int64(position))
            sqlite3_bind_text(statement, 3, "front-\(position + 1).mov", -1, Self.transient)
            sqlite3_bind_text(statement, 4, last.rearFile, -1, Self.transient)
            sqlite3_bind_text(statement, 5, "left-\(position + 1).mov", -1, Self.transient)
            sqlite3_bind_text(statement, 6, "right-\(position + 1).mov", -1, Self.transient)
            sqlite3_bind_double(statement, 7, last.startOffsets.rear + carriedOn)
            sqlite3_bind_double(statement, 8, last.startOffsets.telemetry + carriedOn)
        }
        let id = sqlite3_last_insert_rowid(database)
        guard let segment = try journeySegments(journeyID: journeyID).first(where: { $0.id == id })
        else {
            throw TelemetryStoreError.queryFailed(message: "Segment \(id) vanished on insert.")
        }
        return segment
    }

    /// Rewrites a segment's files, offsets, and length (not its position).
    func updateSegment(_ segment: JourneySegment) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try run(
            database,
            """
            UPDATE journey_segments
            SET front_file = ?, rear_file = ?, left_file = ?, right_file = ?,
                front_offset = ?, rear_offset = ?, telemetry_offset = ?,
                left_offset = ?, right_offset = ?, length = ?
            WHERE id = ?
            """
        ) { statement in
            sqlite3_bind_text(statement, 1, segment.frontFile, -1, Self.transient)
            sqlite3_bind_text(statement, 2, segment.rearFile, -1, Self.transient)
            sqlite3_bind_text(statement, 3, segment.leftFile, -1, Self.transient)
            sqlite3_bind_text(statement, 4, segment.rightFile, -1, Self.transient)
            let offsets = segment.startOffsets
            sqlite3_bind_double(statement, 5, offsets.front)
            sqlite3_bind_double(statement, 6, offsets.rear)
            sqlite3_bind_double(statement, 7, offsets.telemetry)
            Self.bind(offsets.left, to: statement, at: 8)
            Self.bind(offsets.right, to: statement, at: 9)
            Self.bind(segment.length, to: statement, at: 10)
            sqlite3_bind_int64(statement, 11, segment.id)
        }
    }

    /// Removes a segment, closing up the positions after it. A journey's
    /// only segment can't go.
    func deleteSegment(_ segment: JourneySegment) throws {
        guard try journeySegments(journeyID: segment.journeyID).count > 1 else {
            throw TelemetryStoreError.queryFailed(
                message: "A journey needs at least one segment.")
        }
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try transaction(database) {
            try run(database, "DELETE FROM journey_segments WHERE id = ?") {
                sqlite3_bind_int64($0, 1, segment.id)
            }
            // Through negative positions, so no two rows ever share one.
            for sql in [
                "UPDATE journey_segments SET position = -position "
                    + "WHERE journey_id = ? AND position > ?",
                "UPDATE journey_segments SET position = -position - 1 "
                    + "WHERE journey_id = ? AND position < 0",
            ] {
                try run(database, sql) { statement in
                    sqlite3_bind_int64(statement, 1, segment.journeyID)
                    sqlite3_bind_int64(statement, 2, Int64(segment.position))
                }
            }
        }
    }

    /// Swaps a segment with the one before it (`earlier`) or after it in
    /// playback order; a no-op at either end.
    func moveSegment(_ segment: JourneySegment, earlier: Bool) throws {
        let segments = try journeySegments(journeyID: segment.journeyID)
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let otherIndex = earlier ? index - 1 : index + 1
        guard segments.indices.contains(otherIndex) else { return }
        let other = segments[otherIndex]
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }
        try transaction(database) {
            for (id, position) in [
                (segment.id, -1), (other.id, segments[index].position),
                (segment.id, other.position),
            ] {
                try run(database, "UPDATE journey_segments SET position = ? WHERE id = ?") {
                    sqlite3_bind_int64($0, 1, Int64(position))
                    sqlite3_bind_int64($0, 2, id)
                }
            }
        }
    }

    /// Runs `body` in a transaction, rolling back if it throws.
    private func transaction(_ database: OpaquePointer?, _ body: () throws -> Void) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try body()
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Prepares `sql`, binds its parameters with `bind`, and steps it once.
    private func run(
        _ database: OpaquePointer?, _ sql: String, bind: (OpaquePointer?) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Binds `value` to parameter `index`, or NULL for nil.
    private static func bind(_ value: Double?, to statement: OpaquePointer?, at index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: - Writing

    /// The id of the journey whose source directory is `source`, if any.
    func journeyID(source: String) throws -> Int64? {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT id FROM journeys WHERE source = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, source, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// The id of the journey for the given road, if any.
    func journeyID(roadType: String, roadNumber: Int) throws -> Int64? {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT id FROM journeys WHERE road_type = ? AND road_number = ?", -1,
                &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, roadType, -1, Self.transient)
        sqlite3_bind_int64(statement, 2, Int64(roadNumber))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// Inserts a journey row with no telemetry yet, returning its id. Its
    /// one segment's synchronisation offsets keep their 0.0 defaults; the
    /// offset editor fills them in later.
    func insertJourney(
        source: String, roadType: String, roadNumber: Int, title: String
    ) throws -> Int64 {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            let journeyID = try insertJourneyRow(
                database, source: source, roadType: roadType, roadNumber: roadNumber,
                title: title)
            try execute(database, "COMMIT")
            return journeyID
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Rewrites a journey's descriptive fields, leaving the
    /// synchronisation offsets alone. Like inserting, the new `source`
    /// must stay unique, so a clash throws `duplicateJourney`.
    func updateJourney(
        id: Int64, source: String, roadType: String, roadNumber: Int, title: String
    ) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "UPDATE journeys SET source = ?, road_type = ?, road_number = ?, title = ? "
                    + "WHERE id = ?",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, source, -1, Self.transient)
        sqlite3_bind_text(statement, 2, roadType, -1, Self.transient)
        sqlite3_bind_int64(statement, 3, Int64(roadNumber))
        sqlite3_bind_text(statement, 4, title, -1, Self.transient)
        sqlite3_bind_int64(statement, 5, id)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_CONSTRAINT {
                throw TelemetryStoreError.duplicateJourney(source: source)
            }
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Removes a journey and its segments, telemetry, annotations,
    /// route-map labels, and camera overrides in one transaction. The deletes are explicit
    /// rather than relying on the schema's cascades: foreign keys aren't
    /// enforced without PRAGMA foreign_keys, and route_map_labels has no
    /// cascade anyway. Rendered output on disk stays put.
    func deleteJourney(id: Int64) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            for sql in [
                "DELETE FROM route_map_labels WHERE journey_id = ?",
                "DELETE FROM camera_overrides WHERE journey_id = ?",
                "DELETE FROM annotations WHERE journey_id = ?",
                "DELETE FROM telemetry WHERE journey_id = ?",
                "DELETE FROM journey_segments WHERE journey_id = ?",
                "DELETE FROM journeys WHERE id = ?",
            ] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw TelemetryStoreError.queryFailed(
                        message: Self.lastErrorMessage(database))
                }
                defer { sqlite3_finalize(statement) }

                sqlite3_bind_int64(statement, 1, id)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw TelemetryStoreError.queryFailed(
                        message: Self.lastErrorMessage(database))
                }
            }
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    /// Inserts a journey and all its telemetry in one transaction,
    /// returning the new journey's id.
    func insertJourney(
        source: String, roadType: String, roadNumber: Int, title: String,
        samples: [TelemetrySample]
    ) throws -> Int64 {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        try execute(database, "BEGIN IMMEDIATE")
        do {
            let journeyID = try insertJourneyRow(
                database, source: source, roadType: roadType, roadNumber: roadNumber,
                title: title)
            try insertTelemetryRows(database, journeyID: journeyID, samples: samples)
            try execute(database, "COMMIT")
            return journeyID
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private func insertJourneyRow(
        _ database: OpaquePointer?, source: String, roadType: String, roadNumber: Int,
        title: String
    ) throws -> Int64 {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "INSERT INTO journeys (source, road_type, road_number, title) VALUES (?, ?, ?, ?)",
                -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, source, -1, Self.transient)
        sqlite3_bind_text(statement, 2, roadType, -1, Self.transient)
        sqlite3_bind_int64(statement, 3, Int64(roadNumber))
        sqlite3_bind_text(statement, 4, title, -1, Self.transient)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            // The only constraint reachable here is UNIQUE (source):
            // every other column is bound non-null.
            if result == SQLITE_CONSTRAINT {
                throw TelemetryStoreError.duplicateJourney(source: source)
            }
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        let journeyID = sqlite3_last_insert_rowid(database)

        // Every journey starts as one segment over the default files.
        var segment: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "INSERT INTO journey_segments (journey_id, position) VALUES (?, 0)",
                -1, &segment, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(segment) }

        sqlite3_bind_int64(segment, 1, journeyID)
        guard sqlite3_step(segment) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        return journeyID
    }

    private func insertTelemetryRows(
        _ database: OpaquePointer?, journeyID: Int64, samples: [TelemetrySample]
    ) throws {
        let sql = """
            INSERT INTO telemetry (
                journey_id, timestamp, latitude, longitude, altitude,
                speed, heading, accel_forward, accel_lateral,
                speed_limit, file, source, odometer
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        for sample in samples {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_int64(statement, 1, journeyID)
            sqlite3_bind_text(statement, 2, sample.timestamp, -1, Self.transient)
            sqlite3_bind_double(statement, 3, sample.latitude)
            sqlite3_bind_double(statement, 4, sample.longitude)
            sqlite3_bind_double(statement, 5, sample.altitude)
            sqlite3_bind_double(statement, 6, sample.speed)
            sqlite3_bind_double(statement, 7, sample.heading)
            if let accelForward = sample.accelForward {
                sqlite3_bind_double(statement, 8, accelForward)
            }
            if let accelLateral = sample.accelLateral {
                sqlite3_bind_double(statement, 9, accelLateral)
            }
            if let speedLimit = sample.speedLimit {
                sqlite3_bind_int64(statement, 10, Int64(speedLimit))
            }
            if let file = sample.file {
                sqlite3_bind_text(statement, 11, file, -1, Self.transient)
            }
            sqlite3_bind_text(statement, 12, sample.source, -1, Self.transient)
            sqlite3_bind_double(statement, 13, sample.odometer)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
        }
    }

    // MARK: - Roads

    /// Whether `roadName` already has cached endpoints, so a caching sweep
    /// can skip roads it's already looked up.
    func hasCachedRoad(named roadName: String) throws -> Bool {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT 1 FROM roads WHERE road_name = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, roadName, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Inserts `road`, or replaces the existing row for the same
    /// `roadName` if one is already cached.
    func upsertRoad(_ road: CachedRoad) throws {
        let database = try open(flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(database) }

        let sql = """
            INSERT INTO roads (
                road_name, start_easting, start_northing, start_name,
                end_easting, end_northing, end_name,
                start_junction_road, end_junction_road
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (road_name) DO UPDATE SET
                start_easting = excluded.start_easting,
                start_northing = excluded.start_northing,
                start_name = excluded.start_name,
                end_easting = excluded.end_easting,
                end_northing = excluded.end_northing,
                end_name = excluded.end_name,
                start_junction_road = excluded.start_junction_road,
                end_junction_road = excluded.end_junction_road
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, road.roadName, -1, Self.transient)
        sqlite3_bind_double(statement, 2, road.startEasting)
        sqlite3_bind_double(statement, 3, road.startNorthing)
        sqlite3_bind_text(statement, 4, road.startName, -1, Self.transient)
        sqlite3_bind_double(statement, 5, road.endEasting)
        sqlite3_bind_double(statement, 6, road.endNorthing)
        sqlite3_bind_text(statement, 7, road.endName, -1, Self.transient)
        if let startJunctionRoad = road.startJunctionRoad {
            sqlite3_bind_text(statement, 8, startJunctionRoad, -1, Self.transient)
        }
        if let endJunctionRoad = road.endJunctionRoad {
            sqlite3_bind_text(statement, 9, endJunctionRoad, -1, Self.transient)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// The cached endpoints for `roadName`, if any.
    func cachedRoad(named roadName: String) throws -> CachedRoad? {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT road_name, start_easting, start_northing, start_name,
                   end_easting, end_northing, end_name,
                   start_junction_road, end_junction_road
            FROM roads
            WHERE road_name = ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, roadName, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.cachedRoad(from: statement)
    }

    /// Every road cached in the `roads` table, for cycling through during
    /// the intro's slot-machine spin.
    func allCachedRoads() throws -> [CachedRoad] {
        let database = try open(flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(database) }

        let sql = """
            SELECT road_name, start_easting, start_northing, start_name,
                   end_easting, end_northing, end_name,
                   start_junction_road, end_junction_road
            FROM roads
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var roads: [CachedRoad] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
            }
            roads.append(Self.cachedRoad(from: statement))
        }
        return roads
    }

    private static func cachedRoad(from statement: OpaquePointer?) -> CachedRoad {
        CachedRoad(
            roadName: Self.string(statement, column: 0) ?? "",
            startEasting: sqlite3_column_double(statement, 1),
            startNorthing: sqlite3_column_double(statement, 2),
            startName: Self.string(statement, column: 3) ?? "",
            endEasting: sqlite3_column_double(statement, 4),
            endNorthing: sqlite3_column_double(statement, 5),
            endName: Self.string(statement, column: 6) ?? "",
            startJunctionRoad: Self.string(statement, column: 7),
            endJunctionRoad: Self.string(statement, column: 8))
    }

    func open(flags: Int32) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        return database
    }

    func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Tells SQLite to copy bound strings rather than borrow Swift's buffers.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func record(from statement: OpaquePointer?) throws -> TelemetryRecord {
        let rawTimestamp = string(statement, column: 2) ?? ""
        guard let timestamp = try? Date(rawTimestamp, strategy: timestampStrategy) else {
            throw TelemetryStoreError.unparsableTimestamp(rawTimestamp)
        }

        return TelemetryRecord(
            id: sqlite3_column_int64(statement, 0),
            journeyID: sqlite3_column_int64(statement, 1),
            timestamp: timestamp,
            latitude: sqlite3_column_double(statement, 3),
            longitude: sqlite3_column_double(statement, 4),
            altitude: sqlite3_column_double(statement, 5),
            speed: sqlite3_column_double(statement, 6),
            heading: sqlite3_column_double(statement, 7),
            accelForward: double(statement, column: 8),
            accelLateral: double(statement, column: 9),
            speedLimit: integer(statement, column: 10),
            file: string(statement, column: 11),
            source: string(statement, column: 12) ?? "",
            odometer: sqlite3_column_double(statement, 13))
    }

    private static func isNull(_ statement: OpaquePointer?, column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    private static func double(_ statement: OpaquePointer?, column: Int32) -> Double? {
        isNull(statement, column: column) ? nil : sqlite3_column_double(statement, column)
    }

    private static func integer(_ statement: OpaquePointer?, column: Int32) -> Int? {
        isNull(statement, column: column) ? nil : Int(sqlite3_column_int64(statement, column))
    }

    /// The offsets in five consecutive columns from `column`: front, rear,
    /// telemetry, left, right.
    private static func startOffsets(_ statement: OpaquePointer?, column: Int32) -> StartOffsets {
        StartOffsets(
            front: double(statement, column: column) ?? 0,
            rear: double(statement, column: column + 1) ?? 0,
            telemetry: double(statement, column: column + 2) ?? 0,
            left: double(statement, column: column + 3),
            right: double(statement, column: column + 4))
    }

    /// The location in a latitude column and the longitude column after it.
    private static func location(_ statement: OpaquePointer?, column: Int32) -> TrackLocation {
        TrackLocation(
            latitude: sqlite3_column_double(statement, column),
            longitude: sqlite3_column_double(statement, column + 1))
    }

    /// Binds `location` to parameter `index` (latitude) and the one after
    /// it (longitude).
    static func bind(_ location: TrackLocation, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_double(statement, index, location.latitude)
        sqlite3_bind_double(statement, index + 1, location.longitude)
    }

    static func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(decodingCString: text, as: UTF8.self)
    }

    static func lastErrorMessage(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "unknown SQLite error"
        }
        return String(validatingCString: message) ?? "unknown SQLite error"
    }
}
