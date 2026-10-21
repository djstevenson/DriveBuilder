import Foundation
import SQLite3
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

/// Locations along the fixture's A338 for items to sit at.
private let bournemouth = TrackLocation(latitude: 50.76499, longitude: -1.81223)
private let ringwood = TrackLocation(latitude: 50.83991, longitude: -1.81230)
private let salisbury = TrackLocation(latitude: 51.07412, longitude: -1.78681)

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

@Test func insertsUpdatesAndDeletesRouteMapLabels() throws {
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
    #expect(try store.routeMapLabels(journeyID: 1).isEmpty)

    try store.insertRouteMapLabel(
        journeyID: 1, revealLocation: ringwood, title: "A31 Near Ringwood",
        subtitle: "A338/A31 multiplex", location: .left, distance: 75.0)
    try store.insertRouteMapLabel(
        journeyID: 1, revealLocation: bournemouth, title: "A338 Start",
        subtitle: "", location: .right, distance: nil)

    // Reads back in the order added, with the nil distance kept as nil.
    var labels = try store.routeMapLabels(journeyID: 1)
    #expect(labels.map(\.title) == ["A31 Near Ringwood", "A338 Start"])
    #expect(labels.map(\.revealLocation) == [ringwood, bournemouth])
    #expect(labels[0].location == .left)
    #expect(labels[0].distance == 75.0)
    #expect(labels[1].location == .right)
    #expect(labels[1].distance == nil)
    #expect(try store.routeMapLabels(journeyID: 999).isEmpty)

    try store.updateRouteMapLabel(
        id: labels[1].id, revealLocation: salisbury, title: "A338",
        subtitle: "Near Bournemouth", location: .left, distance: 40.0)
    labels = try store.routeMapLabels(journeyID: 1)
    #expect(labels[1].title == "A338")
    #expect(labels[1].revealLocation == salisbury)
    #expect(labels[1].subtitle == "Near Bournemouth")
    #expect(labels[1].location == .left)
    #expect(labels[1].distance == 40.0)

    try store.deleteRouteMapLabel(id: labels[1].id)
    #expect(try store.routeMapLabels(journeyID: 1).map(\.title) == ["A31 Near Ringwood"])
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

@Test func annotationsReadBackInTheOrderAdded() throws {
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
            INSERT INTO annotations (journey_id, video, text, latitude, longitude) VALUES
                (1, 'A27 On', 'We multiplex onto the A27.', 50.84, -1.81),
                (1, 'Start', 'We start our journey.', 50.78, -1.81);
            """,
            nil, nil, nil) == SQLITE_OK)

    let store = TelemetryStore(path: databaseURL.path)
    let annotations = try store.annotations(journeyID: 1)
    // When each ends depends on the track, so rows come back as added.
    #expect(annotations.map(\.video) == ["A27 On", "Start"])
    #expect(annotations.map(\.text) == ["We multiplex onto the A27.", "We start our journey."])
    #expect(
        annotations.map(\.endLocation) == [
            TrackLocation(latitude: 50.84, longitude: -1.81),
            TrackLocation(latitude: 50.78, longitude: -1.81),
        ])
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
    try store.insertAnnotation(
        journeyID: 1, video: "Start", text: "We begin.", endLocation: bournemouth)

    let annotations = try store.annotations(journeyID: 1)
    #expect(annotations.count == 1)
    #expect(annotations[0].video == "Start")
    #expect(annotations[0].text == "We begin.")
    #expect(annotations[0].endLocation == bournemouth)
    #expect(annotations[0].journeyID == 1)

    do {
        try store.insertAnnotation(
            journeyID: 1, video: "Start", text: "Again.", endLocation: ringwood)
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
    try store.insertAnnotation(
        journeyID: 1, video: "Start", text: "We begin.", endLocation: bournemouth)
    try store.insertAnnotation(
        journeyID: 1, video: "A27 On", text: "We multiplex.", endLocation: ringwood)
    let inserted = try store.annotations(journeyID: 1)
    #expect(inserted.map(\.video) == ["Start", "A27 On"])

    // Rewriting every field.
    try store.updateAnnotation(
        id: inserted[0].id, video: "Depart", text: "Off we go.", endLocation: salisbury)
    let updated = try store.annotations(journeyID: 1)
    #expect(updated.map(\.video) == ["Depart", "A27 On"])
    #expect(updated[0].text == "Off we go.")
    #expect(updated[0].endLocation == salisbury)

    // Renaming onto another annotation's video is rejected.
    do {
        try store.updateAnnotation(
            id: updated[0].id, video: "A27 On", text: "Off we go.", endLocation: salisbury)
        Issue.record("expected renaming to a duplicate video to throw")
    } catch TelemetryStoreError.duplicateAnnotation(let video) {
        #expect(video == "A27 On")
    }

    try store.deleteAnnotation(id: updated[1].id)
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

@Test func insertsUpdatesAndDeletesCameraOverrides() throws {
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
    #expect(try store.cameraOverrides(journeyID: 1).isEmpty)

    try store.insertCameraOverride(
        journeyID: 1, camera: .right, start: salisbury, end: ringwood, label: nil)
    try store.insertCameraOverride(
        journeyID: 1, camera: .left, start: bournemouth, end: ringwood,
        label: "Looking left at the old A303")
    var overrides = try store.cameraOverrides(journeyID: 1)
    // In the order added, the default label standing in for NULL.
    #expect(overrides.map(\.camera) == [.right, .left])
    #expect(overrides[0].label == nil)
    #expect(overrides[0].displayLabel == "Right view")
    #expect(overrides[1].displayLabel == "Looking left at the old A303")

    try store.updateCameraOverride(
        id: overrides[1].id, camera: .rear, start: ringwood, end: salisbury, label: nil)
    overrides = try store.cameraOverrides(journeyID: 1)
    #expect(overrides[1].camera == .rear)
    #expect(overrides[1].startLocation == ringwood && overrides[1].endLocation == salisbury)
    #expect(overrides[1].label == nil)

    try store.deleteCameraOverride(id: overrides[1].id)
    #expect(try store.cameraOverrides(journeyID: 1).map(\.camera) == [.right])

    // Deleting the journey takes its overrides with it.
    try store.deleteJourney(id: 1)
    #expect(try store.cameraOverrides(journeyID: 1).isEmpty)
}
