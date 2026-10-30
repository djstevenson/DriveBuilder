import Foundation
import SQLite3
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

/// A copy of the fixture database with the old time-offset tables in place
/// of the location ones, and sync offsets of front 12 s, telemetry 3 s.
/// Returns the copy and its directory, for the caller to remove.
private func oldSchemaDatabase(rows: String) throws -> (path: String, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "location-migration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: url)

    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TelemetryStoreError.openFailed(path: url.path, message: "test setup")
    }
    defer { sqlite3_close(database) }
    let sql = """
        DROP TABLE annotations;
        DROP TABLE camera_overrides;
        DROP TABLE route_map_labels;
        CREATE TABLE annotations (id INTEGER NOT NULL PRIMARY KEY, journey_id INTEGER NOT NULL
            REFERENCES journeys(id) ON DELETE CASCADE, video TEXT NOT NULL, text TEXT NOT NULL,
            offset REAL NOT NULL, UNIQUE (journey_id, video));
        CREATE TABLE camera_overrides (id INTEGER PRIMARY KEY, journey_id INTEGER NOT NULL
            REFERENCES journeys(id) ON DELETE CASCADE, camera TEXT NOT NULL
            CHECK (camera IN ('rear', 'left', 'right')), start_offset REAL NOT NULL,
            end_offset REAL NOT NULL, label TEXT);
        CREATE TABLE route_map_labels (id INTEGER PRIMARY KEY, journey_id INTEGER NOT NULL
            REFERENCES journeys(id), offset REAL NOT NULL, title TEXT NOT NULL,
            subtitle TEXT NOT NULL DEFAULT '', location TEXT NOT NULL DEFAULT 'right',
            distance REAL);
        UPDATE journey_segments SET front_offset = 12, telemetry_offset = 3 WHERE journey_id = 1;
        \(rows)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TelemetryStoreError.queryFailed(
            message: String(cString: sqlite3_errmsg(database)))
    }
    return (url.path, directory)
}

/// The fixture's own samples, and the telemetry seconds of one of them.
private func fixtureRecords() throws -> [TelemetryRecord] {
    try TelemetryStore(path: fixtureDirectory.appending(path: "telemetry.sqlite3").path)
        .records(journeyID: 1)
}

private func seconds(of index: Int, in records: [TelemetryRecord]) -> Double {
    records[index].timestamp.timeIntervalSince(records[0].timestamp)
}

private func isNear(_ location: TrackLocation?, _ record: TelemetryRecord) -> Bool {
    guard let location else { return false }
    return abs(location.latitude - record.latitude) < 1e-7
        && abs(location.longitude - record.longitude) < 1e-7
}

@Test func migrationConvertsEachStoredTimeToWhereTheTrackWas() throws {
    let records = try fixtureRecords()
    // Front-based times are telemetry time - 3 (telemetry offset) + 12
    // (front offset); label times are telemetry time as is.
    let annotationEnd = seconds(of: 10_000, in: records) + 9
    let overrideStart = seconds(of: 20_000, in: records) + 9
    let overrideEnd = seconds(of: 22_000, in: records) + 9
    let labelReveal = seconds(of: 30_000, in: records)
    let (path, directory) = try oldSchemaDatabase(
        rows: """
            INSERT INTO annotations VALUES (1, 1, 'A27 On', 'We multiplex.', \(annotationEnd));
            INSERT INTO camera_overrides VALUES
                (1, 1, 'left', \(overrideStart), \(overrideEnd), 'Looking left');
            INSERT INTO route_map_labels VALUES (1, 1, \(labelReveal), 'Salisbury', '', 'w', 40);
            """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TelemetryStore(path: path)
    #expect(try store.hasTimeOffsetColumns())

    let items = try store.planLocationMigration()
    #expect(items.count == 4)
    #expect(items.allSatisfy { $0.problem == nil })
    #expect(items.allSatisfy { abs($0.driftSeconds ?? .infinity) < 0.01 })
    #expect(isNear(items[0].location, records[10_000]))

    let backup = directory.appending(path: "backup.sqlite3").path
    try store.applyLocationMigration(items, backupPath: backup)
    #expect(try !store.hasTimeOffsetColumns())
    // The backup keeps the old schema.
    #expect(try TelemetryStore(path: backup).hasTimeOffsetColumns())

    let annotation = try #require(try store.annotations(journeyID: 1).first)
    #expect(annotation.video == "A27 On" && annotation.text == "We multiplex.")
    #expect(isNear(annotation.endLocation, records[10_000]))

    let override = try #require(try store.cameraOverrides(journeyID: 1).first)
    #expect(override.camera == .left && override.label == "Looking left")
    #expect(isNear(override.startLocation, records[20_000]))
    #expect(isNear(override.endLocation, records[22_000]))

    let label = try #require(try store.routeMapLabels(journeyID: 1).first)
    #expect(label.title == "Salisbury" && label.location == .w && label.distance == 40)
    #expect(isNear(label.revealLocation, records[30_000]))

    // And they place back at the times they were stored at.
    let placer = try ItemPlacer(store: store, journeyID: 1, records: records)
    let end = try placer.driveSeconds(at: annotation.endLocation, for: "test")
    #expect(abs(end - (annotationEnd - 12)) < 0.01)
}

@Test func migrationRefusesAndChangesNothingIfAnyTimeCantBeConverted() throws {
    let (path, directory) = try oldSchemaDatabase(
        rows: """
            INSERT INTO annotations VALUES (1, 1, 'Fine', 'Fine.', 100);
            INSERT INTO annotations VALUES (2, 1, 'Too late', 'Past the end.', 999999);
            """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TelemetryStore(path: path)

    let items = try store.planLocationMigration()
    #expect(items[0].problem == nil)
    #expect(items[1].problem?.contains("outside the recorded track") == true)

    let backup = directory.appending(path: "backup.sqlite3").path
    #expect(throws: TelemetryStoreError.self) {
        try store.applyLocationMigration(items, backupPath: backup)
    }
    #expect(try store.hasTimeOffsetColumns())
    #expect(!FileManager.default.fileExists(atPath: backup))
}

@Test func itemPlacerShiftsFixesOntoTheDriveSegmentAndNamesItemsOffTheTrack() throws {
    let records = try fixtureRecords()
    let (path, directory) = try oldSchemaDatabase(rows: "")
    defer { try? FileManager.default.removeItem(at: directory) }
    let placer = try ItemPlacer(store: TelemetryStore(path: path), journeyID: 1, records: records)

    let sample = records[15_000]
    let drive = try placer.driveSeconds(
        at: TrackLocation(latitude: sample.latitude, longitude: sample.longitude), for: "test")
    // 3 s of telemetry offset skipped.
    #expect(abs(drive - (seconds(of: 15_000, in: records) - 3)) < 0.01)

    do {
        _ = try placer.driveSeconds(
            at: TrackLocation(latitude: 52, longitude: -4), for: "Annotation \"Nowhere\"")
        Issue.record("expected a location off the track to throw")
    } catch {
        #expect(String(describing: error).contains("Annotation \"Nowhere\""))
        #expect(String(describing: error).contains("never comes within"))
    }
}
