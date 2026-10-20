import Foundation
import SQLite3
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

/// A copy of the fixture database, run through `sql` first, in its own
/// temporary directory for the caller to remove.
private func fixtureCopy(running sql: String = "") throws -> (path: String, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "journey-segment-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: url)

    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TelemetryStoreError.openFailed(path: url.path, message: "test setup")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TelemetryStoreError.queryFailed(message: String(cString: sqlite3_errmsg(database)))
    }
    return (url.path, directory)
}

/// The fixture as it was before segments: offsets and length on the
/// journeys row, and a second journey with side cameras and a length.
private func preSegmentDatabase() throws -> (path: String, directory: URL) {
    try fixtureCopy(
        running: """
            DROP TABLE journey_segments;
            ALTER TABLE journeys ADD COLUMN front_offset REAL NOT NULL DEFAULT 0.0;
            ALTER TABLE journeys ADD COLUMN rear_offset REAL NOT NULL DEFAULT 0.0;
            ALTER TABLE journeys ADD COLUMN telemetry_offset REAL NOT NULL DEFAULT 0.0;
            ALTER TABLE journeys ADD COLUMN length REAL DEFAULT NULL;
            ALTER TABLE journeys ADD COLUMN left_offset REAL DEFAULT NULL;
            ALTER TABLE journeys ADD COLUMN right_offset REAL DEFAULT NULL;
            UPDATE journeys SET front_offset = 53.2, rear_offset = 53.4, telemetry_offset = 76.2
                WHERE id = 1;
            INSERT INTO journeys (id, source, road_number, front_offset, rear_offset,
                telemetry_offset, length, left_offset, right_offset)
                VALUES (2, 'second', 5, 512.1, 516.4, 516.4, 2216.0, 509.8, 509.7);
            """)
}

private func columns(of table: String, in path: String) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK else { return [] }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        names.append(String(cString: sqlite3_column_text(statement, 1)))
    }
    return names
}

// MARK: - Migration

@Test func segmentMigrationMovesEachJourneysOffsetsIntoOneSegment() throws {
    let (path, directory) = try preSegmentDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TelemetryStore(path: path)
    #expect(try store.needsSegmentMigration())

    let backupPath = directory.appending(path: "backup.sqlite3").path
    #expect(try store.applySegmentMigration(backupPath: backupPath) == 2)

    #expect(try !store.needsSegmentMigration())
    #expect(try columns(of: "journeys", in: path) == [
        "id", "source", "road_type", "road_number", "title",
    ])
    #expect(try columns(of: "journeys", in: backupPath).contains("front_offset"))

    let first = try store.journeySegments(journeyID: 1)
    #expect(first.count == 1)
    #expect(first.first?.position == 0)
    #expect(first.first?.frontFile == "front.mov")
    #expect(first.first?.rearFile == "rear.mov")
    #expect(first.first?.startOffsets == StartOffsets(front: 53.2, rear: 53.4, telemetry: 76.2))
    #expect(first.first?.length == nil)

    let second = try #require(try store.journeySegments(journeyID: 2).first)
    #expect(
        second.startOffsets
            == StartOffsets(front: 512.1, rear: 516.4, telemetry: 516.4, left: 509.8, right: 509.7))
    #expect(second.length == 2216.0)
    #expect(second.leftFile == "left.mov")
    #expect(second.rightFile == "right.mov")
}

@Test func segmentMigrationRefusesToOverwriteABackup() throws {
    let (path, directory) = try preSegmentDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backupPath = directory.appending(path: "backup.sqlite3").path
    FileManager.default.createFile(atPath: backupPath, contents: Data("keep".utf8))

    let store = TelemetryStore(path: path)
    #expect(throws: TelemetryStoreError.self) {
        try store.applySegmentMigration(backupPath: backupPath)
    }
    #expect(try store.needsSegmentMigration())
}

// MARK: - Store

@Test func journeysStartAsOneSegmentAndTakeItWithThemWhenDeleted() throws {
    let (path, directory) = try fixtureCopy()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TelemetryStore(path: path)

    let journeyID = try store.insertJourney(
        source: "/tmp/B3347", roadType: "B", roadNumber: 3347, title: "B3347")
    let segments = try store.journeySegments(journeyID: journeyID)
    #expect(segments.map(\.position) == [0])
    #expect(segments.first?.startOffsets == StartOffsets())
    #expect(try store.journeyStartOffsets(journeyID: journeyID) == StartOffsets())

    try store.deleteJourney(id: journeyID)
    #expect(try store.journeySegments(journeyID: journeyID).isEmpty)
}

@Test func segmentsReadBackInPlaybackOrderWithTheFirstOneDrivingTheOldAccessors() throws {
    let (path, directory) = try fixtureCopy(
        running: """
            UPDATE journey_segments SET telemetry_offset = 5, length = 60 WHERE journey_id = 1;
            INSERT INTO journey_segments (journey_id, position, front_file, telemetry_offset)
                VALUES (1, 2, 'front-3.mov', 400);
            INSERT INTO journey_segments (journey_id, position, front_file, telemetry_offset,
                length) VALUES (1, 1, 'front-2.mov', 100, 200);
            """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TelemetryStore(path: path)

    let segments = try store.journeySegments(journeyID: 1)
    #expect(segments.map(\.position) == [0, 1, 2])
    #expect(segments.map(\.frontFile) == ["front.mov", "front-2.mov", "front-3.mov"])
    #expect(segments.map(\.startOffsets.telemetry) == [5, 100, 400])

    #expect(try store.journeyStartOffsets(journeyID: 1)?.telemetry == 5)
    #expect(try store.journeyLength(journeyID: 1) == 60)
    try store.updateLength(journeyID: 1, length: 61)
    #expect(try store.journeySegments(journeyID: 1).map(\.length) == [61, 200, nil])
}

// MARK: - Drive records

private let start = Date(timeIntervalSince1970: 1_775_000_000)

/// One sample per 0.1 s for `seconds`, heading north from 51°N at 0.0001°
/// (about 11 m) a sample, its odometer counting those metres.
private func track(seconds: Int) -> [TelemetryRecord] {
    let step = TelemetrySample.haversineMetres(
        latitude1: 51, longitude1: -1.5, latitude2: 51.0001, longitude2: -1.5)
    return (0..<(seconds * 10)).map { index in
        TelemetryRecord(
            id: Int64(index + 1), journeyID: 1,
            timestamp: start.addingTimeInterval(Double(index) / 10),
            latitude: 51 + Double(index) * 0.0001, longitude: -1.5, altitude: 0, speed: 0,
            heading: 0, accelForward: nil, accelLateral: nil, speedLimit: nil, file: nil,
            source: "test", odometer: Double(index) * step)
    }
}

private func segment(_ position: Int, telemetry offset: Double, length: Double?) -> JourneySegment {
    JourneySegment(
        id: Int64(position + 1), journeyID: 1, position: position, frontFile: "front.mov",
        rearFile: "rear.mov", leftFile: "left.mov", rightFile: "right.mov",
        startOffsets: StartOffsets(telemetry: offset), length: length)
}

private func seconds(_ record: TelemetryRecord) -> Double {
    (record.timestamp.timeIntervalSince(start) * 10).rounded() / 10
}

@Test func oneSegmentSkipsItsOffsetAndStopsAfterItsLength() throws {
    let records = track(seconds: 100)

    let drive = try TelemetryRecord.driveRecords(
        from: records, segments: [segment(0, telemetry: 10, length: 30)])
    // Real timestamps and odometer; the end sample is kept, as before.
    #expect(drive.map(\.id) == Array(101...401))
    #expect(drive.first?.timestamp == records[100].timestamp)
    #expect(drive.last?.odometer == records[400].odometer)

    let toTheEnd = try TelemetryRecord.driveRecords(
        from: records, segments: [segment(0, telemetry: 10, length: nil)])
    #expect(toTheEnd.map(\.id) == Array(101...1000))
}

@Test func laterSegmentsFollowStraightOnAsIfTheCutNeverHappened() throws {
    let records = track(seconds: 100)

    // Keep 10-30 s and 60 s to the end: the drive cuts out 30-60 s.
    let drive = try TelemetryRecord.driveRecords(
        from: records,
        segments: [segment(0, telemetry: 10, length: 20), segment(1, telemetry: 60, length: nil)])
    #expect(drive.map(\.id) == Array(101...300) + Array(601...1000))

    // One sample every 0.1 s across the join: 20 s, then 40 s, from 10 s.
    let times = drive.map(seconds)
    #expect(times.first == 10)
    #expect(times.last == 69.9)
    #expect(zip(times, times.dropFirst()).allSatisfy { abs($1 - $0 - 0.1) < 1e-6 })

    // The odometer carries on from the join, plus the hop across it,
    // leaving out the 30 s cut, rather than jumping to its real reading.
    let beforeJoin = drive[199], afterJoin = drive[200]
    let hop = TelemetrySample.haversineMetres(
        latitude1: beforeJoin.latitude, longitude1: beforeJoin.longitude,
        latitude2: afterJoin.latitude, longitude2: afterJoin.longitude)
    #expect(abs(afterJoin.odometer - (beforeJoin.odometer + hop)) < 1e-6)
    #expect(afterJoin.odometer < records[600].odometer)
    let segmentTwoDistance = records[999].odometer - records[600].odometer
    #expect(abs(drive.last!.odometer - afterJoin.odometer - segmentTwoDistance) < 1e-6)

    // The samples themselves are untouched.
    #expect(afterJoin.latitude == records[600].latitude)
}

@Test func driveRecordsRejectSegmentsThatCannotBeJoined() throws {
    let records = track(seconds: 100)
    func failure(_ segments: [JourneySegment]) -> DriveRecordsError? {
        do {
            _ = try TelemetryRecord.driveRecords(from: records, segments: segments)
            return nil
        } catch {
            return error as? DriveRecordsError
        }
    }

    #expect(failure([]) == .noSegments)
    #expect(
        failure([segment(0, telemetry: 0, length: nil), segment(1, telemetry: 50, length: 10)])
            == .openEndedSegment(position: 0))
    #expect(
        failure([segment(0, telemetry: 0, length: 30), segment(1, telemetry: 20, length: 10)])
            == .overlappingSegment(position: 1))
    let tooShort = failure([
        segment(0, telemetry: 0, length: 30), segment(1, telemetry: 80, length: 30),
    ])
    guard case .telemetryTooShort(let position, let length, let available, let offset) = tooShort
    else {
        Issue.record("expected telemetryTooShort, got \(String(describing: tooShort))")
        return
    }
    #expect(position == 1 && length == 30 && offset == 80)
    #expect(abs(available - 20) < 1e-6)
}
