import Foundation
import SQLite3

enum TelemetryStoreError: Error, CustomStringConvertible {
    case openFailed(path: String, message: String)
    case queryFailed(message: String)
    case unparsableTimestamp(String)
    case journeyNotFound(journeyID: Int64)
    case telemetryNotFound(journeyID: Int64)

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
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        defer { sqlite3_close(database) }

        guard try Self.journeyExists(journeyID: journeyID, database: database) else {
            throw TelemetryStoreError.journeyNotFound(journeyID: journeyID)
        }

        let sql = """
            SELECT id, journey_id, timestamp, latitude, longitude, altitude, speed, heading,
                   accel_forward, accel_lateral, speed_limit, file, source
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

    /// The journey's directory, where its source footage, annotations, and
    /// output live, as recorded by the capture pipeline in `journeys.source`.
    func journeyDirectory(journeyID: Int64) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT source FROM journeys WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.string(statement, column: 0)
    }

    /// The journey's title, as recorded by the capture pipeline in
    /// `journeys.title`.
    func journeyTitle(journeyID: Int64) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT title FROM journeys WHERE id = ?", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.string(statement, column: 0)
    }

    /// The journey's road, as recorded by the capture pipeline in
    /// `journeys.road_type`/`journeys.road_number`, e.g. ("A", 338).
    func journeyRoad(journeyID: Int64) throws -> (type: String, number: Int)? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT road_type, road_number FROM journeys WHERE id = ?", -1,
                &statement, nil)
                == SQLITE_OK
        else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, journeyID)
        guard sqlite3_step(statement) == SQLITE_ROW, let type = Self.string(statement, column: 0)
        else { return nil }
        return (type: type, number: Int(sqlite3_column_int64(statement, 1)))
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

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
        return sqlite3_last_insert_rowid(database)
    }

    private func insertTelemetryRows(
        _ database: OpaquePointer?, journeyID: Int64, samples: [TelemetrySample]
    ) throws {
        let sql = """
            INSERT INTO telemetry (
                journey_id, timestamp, latitude, longitude, altitude,
                speed, heading, accel_forward, accel_lateral,
                speed_limit, file, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

    private func open(flags: Int32) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let message = Self.lastErrorMessage(database)
            sqlite3_close(database)
            throw TelemetryStoreError.openFailed(path: path, message: message)
        }
        return database
    }

    private func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TelemetryStoreError.queryFailed(message: Self.lastErrorMessage(database))
        }
    }

    /// Tells SQLite to copy bound strings rather than borrow Swift's buffers.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
            source: string(statement, column: 12) ?? "")
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

    private static func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(decodingCString: text, as: UTF8.self)
    }

    private static func lastErrorMessage(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "unknown SQLite error"
        }
        return String(validatingCString: message) ?? "unknown SQLite error"
    }
}
