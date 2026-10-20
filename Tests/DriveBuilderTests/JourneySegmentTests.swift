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

// MARK: - Timeline

/// Two segments: 20 s from front.mov at 5 s (telemetry 10 s), then the
/// rest from front-2.mov at 2 s (rear 300 s, telemetry 60 s), which also
/// has a left camera; final.mov's drive starts 40 s in.
private func twoSegmentTimeline() -> JourneyTimeline {
    var second = segment(1, telemetry: 60, length: nil)
    second.frontFile = "front-2.mov"
    second.startOffsets.front = 2
    second.startOffsets.rear = 300
    second.startOffsets.left = 1
    var first = segment(0, telemetry: 10, length: 20)
    first.startOffsets.front = 5
    return JourneyTimeline(segments: [first, second], driveSegmentStart: 40)
}

@Test func timelineReadsEachSegmentsSourcesAtItsOwnOffsets() {
    let timeline = twoSegmentTimeline()
    #expect(timeline.spans.map(\.driveStart) == [0, 20])
    #expect(timeline.segmentIndex(atDriveSeconds: -5) == 0)
    #expect(timeline.segmentIndex(atDriveSeconds: 19.9) == 0)
    #expect(timeline.segmentIndex(atDriveSeconds: 20) == 1)

    // 10 s into the drive is in the first segment...
    #expect(timeline.seconds(10, on: .front) == 15)
    #expect(timeline.seconds(10, on: .telemetry) == 20)
    #expect(timeline.seconds(10, on: .final) == 50)
    #expect(timeline.seconds(10, on: .left) == nil)
    // ...and 25 s is 5 s into the second, which starts its sources afresh,
    // while final.mov runs straight on.
    #expect(timeline.seconds(25, on: .front) == 7)
    #expect(timeline.seconds(25, on: .rear) == 305)
    #expect(timeline.seconds(25, on: .telemetry) == 65)
    #expect(timeline.seconds(25, on: .left) == 6)
    #expect(timeline.seconds(25, on: .final) == 65)

    #expect(timeline.driveSeconds(7, on: .front, segment: 1) == 25)
    #expect(timeline.driveSeconds(65, on: .final) == 25)
    #expect(timeline.convert(15, from: .front, segment: 0, to: .final) == 50)
    #expect(timeline.convert(7, from: .front, segment: 1, to: .rear) == 305)
    #expect(timeline.hasClock(.left))
    #expect(!timeline.hasClock(.right))
}

// MARK: - Placing on the drive

private let junctionLatitude = 51.01

/// A wrong turn: north to a junction (10 s), on past it (10 s), a U-turn
/// back to it (10 s), then east along the right road (20 s); about 11 m a
/// sample.
private func wrongTurn() -> [TelemetryRecord] {
    var points: [(latitude: Double, longitude: Double)] = []
    for index in 0..<500 {
        switch index {
        case ..<200: points.append((51 + Double(index) * 0.0001, -1.5))
        case ..<300: points.append((51 + Double(400 - index) * 0.0001, -1.5))
        default: points.append((junctionLatitude, -1.5 + Double(index - 300) * 0.00016))
        }
    }
    var odometer = 0.0
    return points.enumerated().map { index, point in
        if index > 0 {
            odometer += TelemetrySample.haversineMetres(
                latitude1: points[index - 1].latitude, longitude1: points[index - 1].longitude,
                latitude2: point.latitude, longitude2: point.longitude)
        }
        return TelemetryRecord(
            id: Int64(index + 1), journeyID: 1,
            timestamp: start.addingTimeInterval(Double(index) / 10),
            latitude: point.latitude, longitude: point.longitude, altitude: 0, speed: 0,
            heading: 0, accelForward: nil, accelLateral: nil, speedLimit: nil, file: nil,
            source: "test", odometer: odometer)
    }
}

/// The wrong turn with the detour cut out: up to the junction, then from
/// arriving back at it, in front-2.mov.
private func wrongTurnPlacement() throws -> JourneyPlacement {
    var second = segment(1, telemetry: 30, length: nil)
    second.frontFile = "front-2.mov"
    return JourneyPlacement(
        track: try DriveTrack(
            records: wrongTurn(), segments: [segment(0, telemetry: 0, length: 10), second]))
}

@Test func placingOnTheDriveIgnoresPassesInTheCutOutDetour() throws {
    let placement = try wrongTurnPlacement()

    // Just past the junction, the whole recording passes twice (out along
    // the wrong road and back), but the drive only once, at the join.
    let pastJunction = TrackLocation(latitude: junctionLatitude + 0.00009, longitude: -1.5)
    do {
        _ = try TrackLocator(records: wrongTurn()).locate(pastJunction)
        Issue.record("expected the whole recording to pass the junction twice")
    } catch {
        guard case .ambiguous(let seconds) = error, seconds.count == 2 else {
            Issue.record("expected two passes, got \(error)")
            return
        }
    }
    let placed = try placement.place(pastJunction).get()
    #expect(abs(placed.driveSeconds - 10) < 0.05)

    // Along the right road, 5 s after the join, in the second segment.
    let along = TrackLocation(latitude: junctionLatitude, longitude: -1.5 + 50 * 0.00016)
    let alongPlaced = try placement.place(along).get()
    #expect(abs(alongPlaced.driveSeconds - 15) < 1e-6)
    #expect(placement.movieName(on: .front, at: alongPlaced) == "front-2.mov")
    #expect(abs((placement.seconds(alongPlaced, on: .front) ?? 0) - 5) < 1e-6)
    let found = try #require(placement.location(atSeconds: 5, on: .front, segment: 1))
    #expect(abs(found.longitude - along.longitude) < 1e-9)

    // On the wrong road itself: only the cut-out part passes it.
    let onDetour = TrackLocation(latitude: junctionLatitude + 0.005, longitude: -1.5)
    #expect(placement.place(onDetour) == .failure(.cutOut))
    let nowhere = TrackLocation(latitude: 52, longitude: -1.5)
    guard case .failure(.tooFar) = placement.place(nowhere) else {
        Issue.record("expected a location off the route to be too far")
        return
    }
}

@Test func keepingEndsLeavesOutOnlyWhatLiesBetweenSegments() throws {
    let records = track(seconds: 100)
    let drive = try TelemetryRecord.driveRecords(
        from: records,
        segments: [segment(0, telemetry: 10, length: 20), segment(1, telemetry: 60, length: 20)],
        keepingEnds: true)
    // The lead-in before 10 s at its real time, then the segments, then
    // the run-out past the second segment's end, moved back with it.
    #expect(drive.map(\.id) == Array(1...300) + Array(601...1000))
    #expect(drive.first?.timestamp == start)
    #expect(drive.last.map(seconds) == 69.9)
}

@Test func itemsBeforeTheDriveStartPlaceAtNegativeDriveSeconds() throws {
    // A label pinned at the very first sample, before a 3 s telemetry
    // offset, places 3 s before the drive starts, as before segments.
    let records = track(seconds: 100)
    let drive = try DriveTrack(records: records, segments: [segment(0, telemetry: 3, length: 20)])
    let first = TrackLocation(latitude: records[0].latitude, longitude: records[0].longitude)
    #expect(abs(try drive.locate(first).seconds + 3) < 1e-6)
    // And one past the end, after it.
    let late = TrackLocation(latitude: records[500].latitude, longitude: records[500].longitude)
    #expect(abs(try drive.locate(late).seconds - 47) < 1e-6)
}
