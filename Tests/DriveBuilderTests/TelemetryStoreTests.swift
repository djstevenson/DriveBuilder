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
            file: "260726_153931_001_FH.MP4", source: "GPS"),
        TelemetrySample(
            tick: baseTick + 1, latitude: 50.77, longitude: -1.82, altitude: 23.6, speed: 1.2,
            heading: 161, accelForward: nil, accelLateral: nil, speedLimit: nil,
            file: nil, source: "Interpolated"),
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
    #expect(records[1].accelForward == nil)
    #expect(records[1].speedLimit == nil)
    #expect(records[1].file == nil)
    #expect(records[1].source == "Interpolated")
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
