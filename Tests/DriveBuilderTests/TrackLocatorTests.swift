import CoreMedia
import Foundation
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

private let metresPerDegree = 6_371_000.0 * .pi / 180
private let originLatitude = 51.0
private let originLongitude = -1.8
private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A location `north` and `east` metres from the synthetic tracks' origin.
private func location(north: Double, east: Double = 0) -> TrackLocation {
    TrackLocation(
        latitude: originLatitude + north / metresPerDegree,
        longitude: originLongitude
            + east / (metresPerDegree * cos(originLatitude * .pi / 180)))
}

/// A 10 Hz track through `points` (north, east metres from the origin),
/// with the odometer accumulated along it.
private func track(_ points: [(north: Double, east: Double)]) -> [TelemetryRecord] {
    var odometer = 0.0
    return points.enumerated().map { index, point in
        if index > 0 {
            let previous = points[index - 1]
            odometer += hypot(point.north - previous.north, point.east - previous.east)
        }
        let here = location(north: point.north, east: point.east)
        return TelemetryRecord(
            id: Int64(index), journeyID: 1,
            timestamp: start.addingTimeInterval(Double(index) * TelemetryRecord.sampleInterval),
            latitude: here.latitude, longitude: here.longitude, altitude: 0, speed: 0,
            heading: 0, accelForward: nil, accelLateral: nil, speedLimit: nil, file: nil,
            source: "test", odometer: odometer)
    }
}

/// Heading due north at 70 mph (about 3.13 m per 10 Hz sample).
private func northbound(samples: Int = 1000, east: (Int) -> Double = { _ in 0 })
    -> [TelemetryRecord]
{
    track((0..<samples).map { (Double($0) * 3.13, east($0)) })
}

// MARK: - TrackLocation

@Test func trackLocationParsesPastedAndDisplayedCoordinates() {
    let expected = TrackLocation(latitude: 51.0712, longitude: -1.7983)
    #expect(TrackLocation(parsing: "51.0712, -1.7983") == expected)
    #expect(TrackLocation(parsing: " 51.0712,-1.7983 ") == expected)
    #expect(TrackLocation(parsing: "51.0712 -1.7983") == expected)
    #expect(TrackLocation(parsing: "51.0712° N, 1.7983° W") == expected)
    #expect(TrackLocation(parsing: "51.0712°N, 1.7983°W") == expected)
    #expect(TrackLocation(parsing: "51.0712n 1.7983w") == expected)
    #expect(
        TrackLocation(parsing: "33.8° S, 151.2° E")
            == TrackLocation(latitude: -33.8, longitude: 151.2))
}

@Test func trackLocationRejectsMalformedOrOutOfRangeCoordinates() {
    #expect(TrackLocation(parsing: "") == nil)
    #expect(TrackLocation(parsing: "51.0712") == nil)
    #expect(TrackLocation(parsing: "51.0712, -1.7983, 4") == nil)
    #expect(TrackLocation(parsing: "abc, def") == nil)
    // A sign and a hemisphere together would be ambiguous.
    #expect(TrackLocation(parsing: "51.0712° N, -1.7983° W") == nil)
    // Hemispheres in the wrong order.
    #expect(TrackLocation(parsing: "1.7983° W, 51.0712° N") == nil)
    #expect(TrackLocation(parsing: "91, 0") == nil)
    #expect(TrackLocation(parsing: "0, 181") == nil)
}

@Test func trackLocationTextRoundTrips() throws {
    let location = TrackLocation(latitude: 51.071234, longitude: -1.798311)
    #expect(location.text == "51.07123°N, 1.79831°W")
    let parsed = try #require(TrackLocation(parsing: location.text))
    #expect(abs(parsed.latitude - location.latitude) < 0.00001)
    #expect(abs(parsed.longitude - location.longitude) < 0.00001)
}

// MARK: - TrackLocator

@Test func locatorInterpolatesBetweenSamples() throws {
    // Halfway between samples 100 and 101.
    let fix = try TrackLocator(records: northbound()).locate(location(north: 100.5 * 3.13))
    #expect(fix.sampleIndex == 100)
    #expect(abs(fix.fraction - 0.5) < 1e-6)
    #expect(abs(fix.telemetrySeconds - 10.05) < 1e-6)
    #expect(abs(fix.odometerMetres - 100.5 * 3.13) < 1e-6)
    #expect(fix.distanceMetres < 0.01)
}

@Test func locatorAcceptsAPinBesideTheTrack() throws {
    let fix = try TrackLocator(records: northbound()).locate(location(north: 500, east: 20))
    #expect(abs(fix.distanceMetres - 20) < 0.01)
    #expect(abs(fix.telemetrySeconds - 500 / 3.13 / 10) < 1e-3)
}

@Test func locatorRejectsAPinTooFarFromTheTrack() {
    #expect(throws: TrackLocatorError.self) {
        try TrackLocator(records: northbound()).locate(location(north: 500, east: 50))
    }
    do {
        _ = try TrackLocator(records: northbound()).locate(location(north: 500, east: 50))
    } catch .tooFar(let nearest, let threshold) {
        #expect(abs(nearest - 50) < 0.01)
        #expect(threshold == TrackLocator.defaultThresholdMetres)
    } catch {
        Issue.record("expected tooFar, got \(error)")
    }
}

@Test func locatorRejectsALocationPassedTwice() {
    // Out 1 km and straight back.
    let out = (0...320).map { (Double($0) * 3.13, 0.0) }
    let records = track(out + out.reversed().dropFirst())
    do {
        _ = try TrackLocator(records: records).locate(location(north: 300))
        Issue.record("expected the location to be ambiguous")
    } catch .ambiguous(let seconds) {
        #expect(seconds.count == 2)
        #expect(abs(seconds[0] - 300 / 3.13 / 10) < 1e-3)
        #expect(abs(seconds[1] - (64 - 300 / 3.13 / 10)) < 1e-3)
    } catch {
        Issue.record("expected ambiguous, got \(error)")
    }
}

@Test func locatorTreatsGPSJitterNearThePinAsOnePass() throws {
    // The track runs 25 m to one side, but one fix near the pin wanders out
    // past the threshold, splitting the stretch within it in two.
    let records = northbound { $0 == 160 ? 40 : 25 }
    let fix = try TrackLocator(records: records).locate(location(north: 160 * 3.13))
    #expect(fix.distanceMetres < 26)
}

@Test func locatorMarksArrivingWhenTheTrackLingersNearThePin() throws {
    // Stopped 0.5 m short of the pin for ten seconds from sample 100, then
    // driving on through it.
    let approach: [(north: Double, east: Double)] = (0..<100).map { (Double($0) * 3.13, 0) }
    let queue: [(north: Double, east: Double)] = Array(
        repeating: (100 * 3.13 - 0.5, 0), count: 100)
    let onwards: [(north: Double, east: Double)] = (100..<300).map { (Double($0) * 3.13, 0) }
    let points = approach + queue + onwards
    let fix = try TrackLocator(records: track(points)).locate(location(north: 100 * 3.13))
    // Arriving at the queue (sample 99's segment ends there), not leaving it.
    #expect(fix.telemetrySeconds < 10.01)
}

@Test func locatorRejectsAnEmptyTrack() {
    #expect(throws: TrackLocatorError.emptyTrack) {
        try TrackLocator(records: []).locate(location(north: 0))
    }
}

@Test func locatorFindsTheFixtureJourneysOwnSamples() throws {
    let records = try TelemetryStore(
        path: fixtureDirectory.appending(path: "telemetry.sqlite3").path
    ).records(journeyID: 1)
    let locator = TrackLocator(records: records)
    for index in [1_000, 20_000, 37_000] {
        let sample = records[index]
        let fix = try locator.locate(
            TrackLocation(latitude: sample.latitude, longitude: sample.longitude))
        let expected = sample.timestamp.timeIntervalSince(records[0].timestamp)
        #expect(abs(fix.telemetrySeconds - expected) <= TelemetryRecord.sampleInterval)
        #expect(fix.distanceMetres < 0.01)
    }
}

// MARK: - JourneyTimeline

@Test func timelineConvertsBetweenClocks() throws {
    var offsets = StartOffsets()
    offsets.front = 12
    offsets.telemetry = 3.5
    let timeline = JourneyTimeline(startOffsets: offsets, driveSegmentStart: 40)
    #expect(timeline.driveSeconds(100, on: .front) == 88)
    #expect(timeline.driveSeconds(100, on: .telemetry) == 96.5)
    #expect(timeline.driveSeconds(128, on: .final) == 88)
    #expect(timeline.convert(100, from: .front, to: .final) == 128)
    #expect(timeline.convert(100, from: .front, to: .telemetry) == 91.5)
    // Round trips through every clock.
    for clock in JourneyTimeline.Clock.allCases {
        let there = try #require(timeline.convert(250.25, from: .front, to: clock))
        #expect(timeline.convert(there, from: clock, to: .front) == 250.25)
    }
}

@Test func timelineHasNoFinalClockUntilTheDriveSegmentStartIsKnown() {
    let timeline = JourneyTimeline(startOffsets: StartOffsets())
    #expect(timeline.seconds(10, on: .final) == nil)
    #expect(timeline.driveSeconds(10, on: .final) == nil)
    #expect(timeline.convert(10, from: .front, to: .telemetry) == 10)
}

@Test func driveSegmentStartsAfterTheIntroAndRouteMapLessTheirCrossFades() {
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    let start = JourneyTimeline.driveSegmentStart(
        introDuration: time(10), routeMapDuration: time(20), crossFade: time(1))
    #expect(start == time(28))
}
