import Foundation
import SQLite3
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

@Test func loadsRecordsAndDirectoryForAnExistingJourney() throws {
    let store = TelemetryStore(path: fixtureDirectory.appending(path: "telemetry.sqlite3").path)
    #expect(try store.records(journeyID: 1).count == 38397)
    // The fixture's source is a placeholder string, never resolved to a real
    // directory, so it doesn't matter that it isn't a real machine path.
    #expect(try store.journeyDirectory(journeyID: 1) == "Fixtures/A338 Northbound")
}

@Test func throwsJourneyNotFoundForAnUnknownJourneyID() throws {
    let store = TelemetryStore(path: fixtureDirectory.appending(path: "telemetry.sqlite3").path)
    do {
        _ = try store.records(journeyID: 999_999)
        Issue.record("expected loading an unknown journey to throw")
    } catch TelemetryStoreError.journeyNotFound(let journeyID) {
        #expect(journeyID == 999_999)
    }
}

@Test func findsJourneysBySourceAndByRoad() throws {
    let store = TelemetryStore(path: fixtureDirectory.appending(path: "telemetry.sqlite3").path)
    #expect(try store.journeyID(source: "Fixtures/A338 Northbound") == 1)
    #expect(try store.journeyID(source: "/nowhere") == nil)
    #expect(try store.journeyID(roadType: "A", roadNumber: 338) == 1)
    #expect(try store.journeyID(roadType: "M", roadNumber: 27) == nil)
}

@Test func insertsAJourneyAndReadsItBack() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    let epoch = try Date("2026-07-26T14:37:55Z", strategy: .iso8601).timeIntervalSince1970
    let baseTick = Int64(epoch) * 10
    let samples = [
        TelemetrySample(
            tick: baseTick, latitude: 50.76, longitude: -1.81, altitude: 23.5, speed: 0.98,
            heading: 160.29, accelForward: 0.01, accelLateral: -0.02, speedLimit: 30,
            file: "260726_153931_001_FH.MP4", source: "GPS", odometer: 0),
        TelemetrySample(
            tick: baseTick + 1, latitude: 50.77, longitude: -1.82, altitude: 23.6, speed: 1.2,
            heading: 161, accelForward: nil, accelLateral: nil, speedLimit: nil,
            file: nil, source: "Interpolated", odometer: 12.3),
    ]

    let store = TelemetryStore(path: databaseURL.path)
    let journeyID = try store.insertJourney(
        source: "/tmp/B3347 Southbound", roadType: "B", roadNumber: 3347,
        title: "B3347 Southbound", samples: samples)

    #expect(try store.journeyID(source: "/tmp/B3347 Southbound") == journeyID)
    #expect(try store.journeyID(roadType: "B", roadNumber: 3347) == journeyID)

    let records = try store.records(journeyID: journeyID)
    #expect(records.count == 2)
    #expect(abs(records[0].timestamp.timeIntervalSince1970 - epoch) < 1e-6)
    #expect(abs(records[1].timestamp.timeIntervalSince1970 - (epoch + 0.1)) < 1e-6)
    #expect(records[0].latitude == 50.76)
    #expect(records[0].speedLimit == 30)
    #expect(records[0].file == "260726_153931_001_FH.MP4")
    #expect(records[0].odometer == 0)
    #expect(records[1].accelForward == nil)
    #expect(records[1].speedLimit == nil)
    #expect(records[1].file == nil)
    #expect(records[1].source == "Interpolated")
    #expect(records[1].odometer == 12.3)
}

@Test func updatesEachStartOffsetIndependently() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    let store = TelemetryStore(path: databaseURL.path)
    var offsets = try #require(try store.journeyStartOffsets(journeyID: 1))
    #expect(offsets.front == 0)
    #expect(offsets.rear == 0)
    #expect(offsets.telemetry == 0)

    try store.updateStartOffset(journeyID: 1, source: .front, offset: 34.0)
    try store.updateStartOffset(journeyID: 1, source: .rear, offset: 34.5)
    try store.updateStartOffset(journeyID: 1, source: .telemetry, offset: 62.0)

    offsets = try #require(try store.journeyStartOffsets(journeyID: 1))
    #expect(offsets.front == 34.0)
    #expect(offsets.rear == 34.5)
    #expect(offsets.telemetry == 62.0)
}

@Test func cachesAndReadsBackARoadsEndpoints() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    let store = TelemetryStore(path: databaseURL.path)
    #expect(try store.hasCachedRoad(named: "A338") == false)
    #expect(try store.cachedRoad(named: "A338") == nil)

    let road = CachedRoad(
        roadName: "A338",
        startEasting: 406660.1875, startNorthing: 91592.828125, startName: "Westbourne",
        endEasting: 445103.25, endNorthing: 200662.484375, endName: "Appleton",
        startJunctionRoad: "A35", endJunctionRoad: "A420")
    try store.upsertRoad(road)

    #expect(try store.hasCachedRoad(named: "A338") == true)
    let cached = try store.cachedRoad(named: "A338")
    #expect(cached?.startName == "Westbourne")
    #expect(cached?.endName == "Appleton")
    #expect(cached?.startEasting == 406660.1875)
    #expect(cached?.endNorthing == 200662.484375)
    #expect(cached?.startJunctionRoad == "A35")
    #expect(cached?.endJunctionRoad == "A420")

    // Upserting the same road name replaces rather than duplicating.
    try store.upsertRoad(
        CachedRoad(
            roadName: "A338",
            startEasting: 1, startNorthing: 2, startName: "Replaced Start",
            endEasting: 3, endNorthing: 4, endName: "Replaced End",
            startJunctionRoad: nil, endJunctionRoad: nil))
    let replaced = try store.cachedRoad(named: "A338")
    #expect(replaced?.startName == "Replaced Start")
    #expect(replaced?.endName == "Replaced End")
    #expect(replaced?.startJunctionRoad == nil)
    #expect(replaced?.endJunctionRoad == nil)
}

@Test func journeyWithNoAnnotationsReadsBackEmpty() throws {
    let store = TelemetryStore(path: fixtureDirectory.appending(path: "telemetry.sqlite3").path)
    #expect(try store.annotations(journeyID: 1).isEmpty)
}

@Test func annotationsReadBackInOffsetOrder() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(
        sqlite3_exec(
            database,
            """
            INSERT INTO annotations (journey_id, video, text, offset) VALUES
                (1, 'A27 On', 'We multiplex onto the A27.', 120.0),
                (1, 'Start', 'We start our journey.', 30.0);
            """,
            nil, nil, nil) == SQLITE_OK)

    let store = TelemetryStore(path: databaseURL.path)
    let annotations = try store.annotations(journeyID: 1)
    // Rows come back in offset order, not insertion order.
    #expect(annotations.map(\.video) == ["Start", "A27 On"])
    #expect(annotations.map(\.text) == ["We start our journey.", "We multiplex onto the A27."])
    #expect(annotations.map(\.offset) == [30.0, 120.0])
    #expect(annotations.map(\.journeyID) == [1, 1])

    // A journey with no rows of its own doesn't see another's.
    #expect(try store.annotations(journeyID: 999_999).isEmpty)
}

@Test func insertsAnAnnotationAndRejectsDuplicateVideoNames() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    let store = TelemetryStore(path: databaseURL.path)
    try store.insertAnnotation(journeyID: 1, video: "Start", text: "We begin.", offset: 94.5)

    let annotations = try store.annotations(journeyID: 1)
    #expect(annotations.count == 1)
    #expect(annotations[0].video == "Start")
    #expect(annotations[0].text == "We begin.")
    #expect(annotations[0].offset == 94.5)
    #expect(annotations[0].journeyID == 1)

    do {
        try store.insertAnnotation(journeyID: 1, video: "Start", text: "Again.", offset: 200)
        Issue.record("expected a duplicate video name to throw")
    } catch TelemetryStoreError.duplicateAnnotation(let video) {
        #expect(video == "Start")
    }
    // The failed insert left nothing behind.
    #expect(try store.annotations(journeyID: 1).count == 1)
}

@Test func updatesAndDeletesAnnotations() throws {
    // Copy the fixture database rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    let store = TelemetryStore(path: databaseURL.path)
    try store.insertAnnotation(journeyID: 1, video: "Start", text: "We begin.", offset: 30)
    try store.insertAnnotation(journeyID: 1, video: "A27 On", text: "We multiplex.", offset: 120)
    let inserted = try store.annotations(journeyID: 1)
    #expect(inserted.map(\.video) == ["Start", "A27 On"])

    // Rewriting every field, including a new offset that reorders the rows.
    try store.updateAnnotation(
        id: inserted[0].id, video: "Depart", text: "Off we go.", offset: 150)
    let updated = try store.annotations(journeyID: 1)
    #expect(updated.map(\.video) == ["A27 On", "Depart"])
    #expect(updated[1].text == "Off we go.")
    #expect(updated[1].offset == 150)

    // Renaming onto another annotation's video is rejected.
    do {
        try store.updateAnnotation(
            id: updated[1].id, video: "A27 On", text: "Off we go.", offset: 150)
        Issue.record("expected renaming to a duplicate video to throw")
    } catch TelemetryStoreError.duplicateAnnotation(let video) {
        #expect(video == "A27 On")
    }

    try store.deleteAnnotation(id: updated[0].id)
    #expect(try store.annotations(journeyID: 1).map(\.video) == ["Depart"])
}

@Test func throwsTelemetryNotFoundForAJourneyWithNoTelemetry() throws {
    // Copy the fixture database and add a journey row with no telemetry rows,
    // rather than mutating the checked-in fixture.
    let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "telemetry-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let databaseURL = tempDirectory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(
        at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: databaseURL)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(
        sqlite3_exec(
            database, "INSERT INTO journeys (id, source) VALUES (2, 'empty journey')", nil, nil,
            nil) == SQLITE_OK)

    let store = TelemetryStore(path: databaseURL.path)
    do {
        _ = try store.records(journeyID: 2)
        Issue.record("expected loading a journey with no telemetry to throw")
    } catch TelemetryStoreError.telemetryNotFound(let journeyID) {
        #expect(journeyID == 2)
    }
}
