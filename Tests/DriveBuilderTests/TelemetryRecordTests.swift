import Foundation
import Testing

@testable import DriveBuilder

private func record(
    latitude: Double = 0, longitude: Double = 0, altitude: Double = 0, speed: Double = 0,
    heading: Double = 0, accelForward: Double? = nil, accelLateral: Double? = nil,
    timestamp: Date = .distantPast
) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        speed: speed,
        heading: heading,
        accelForward: accelForward,
        accelLateral: accelLateral,
        speedLimit: 30,
        file: nil,
        source: "test")
}

// MARK: - Interpolation

@Test func headingInterpolationTakesTheShortestArc() {
    // Like the Perl, results are not normalised to 0..<360: crossing north
    // from 350° to 10° passes through 360°, the same rotation as 0°.
    #expect(TelemetryRecord.interpolateHeading(from: 350, to: 10, fraction: 0.5) == 360)
    #expect(TelemetryRecord.interpolateHeading(from: 10, to: 350, fraction: 0.5) == 0)
    #expect(TelemetryRecord.interpolateHeading(from: 90, to: 120, fraction: 0.5) == 105)
}

@Test func recordsInterpolateLinearly() {
    let start = Date(timeIntervalSince1970: 1_775_000_000)
    let a = record(latitude: 51.0, longitude: -1.5, heading: 30, timestamp: start)
    let b = record(
        latitude: 51.001, longitude: -1.499, heading: 40,
        timestamp: start.addingTimeInterval(0.1))

    let mid = TelemetryRecord.interpolated(from: a, to: b, fraction: 0.5)
    #expect(abs(mid.latitude - 51.0005) < 1e-9)
    #expect(abs(mid.longitude - -1.4995) < 1e-9)
    #expect(abs(mid.heading - 35) < 1e-9)
    #expect(abs(mid.timestamp.timeIntervalSince(start) - 0.05) < 1e-6)
    #expect(mid.source == "Interpolated")
}

@Test func interpolatedRecordLerpsAcceleration() {
    let a = record(accelForward: 0, accelLateral: 0)
    let b = record(accelForward: 1, accelLateral: -1)
    let mid = TelemetryRecord.interpolated(from: a, to: b, fraction: 0.5)
    #expect(mid.accelForward == 0.5)
    #expect(mid.accelLateral == -0.5)
}

@Test func interpolatedAccelerationIsNilIfEitherEndpointLacksIt() {
    let a = record(accelForward: nil, accelLateral: 0)
    let b = record(accelForward: 1, accelLateral: -1)
    let mid = TelemetryRecord.interpolated(from: a, to: b, fraction: 0.5)
    #expect(mid.accelForward == nil)
    // Lateral is present on both endpoints, so it still lerps.
    #expect(mid.accelLateral == -0.5)
}

@Test func interpolatedRecordCarriesTheSpeedLimitForward() {
    let a = TelemetryRecord(
        id: 1, journeyID: 1, timestamp: .distantPast, latitude: 0, longitude: 0, altitude: 0,
        speed: 0, heading: 0, accelForward: nil, accelLateral: nil, speedLimit: 40, file: nil,
        source: "test")
    let b = TelemetryRecord(
        id: 2, journeyID: 1, timestamp: .distantPast, latitude: 0, longitude: 0, altitude: 0,
        speed: 0, heading: 0, accelForward: nil, accelLateral: nil, speedLimit: 60, file: nil,
        source: "test")
    #expect(TelemetryRecord.interpolated(from: a, to: b, fraction: 0.5).speedLimit == 40)
}

@Test func subframeSequenceInsertsInterpolatedRecordsBetweenEachPair() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let records = (0..<3).map {
        record(latitude: Double($0), timestamp: start.addingTimeInterval(Double($0)))
    }
    let frames = TelemetryRecord.subframeSequence(records, subframesPerRecord: 3)

    // 3 originals, each pair preceded by 2 interpolated subframes.
    #expect(frames.count == 7)
    // Original records land unchanged at 0, 3, 6.
    #expect(frames[0].latitude == 0)
    #expect(frames[3].latitude == 1)
    #expect(frames[6].latitude == 2)
    // The two subframes between them are evenly spaced thirds.
    #expect(abs(frames[1].latitude - 1.0 / 3) < 1e-9)
    #expect(abs(frames[2].latitude - 2.0 / 3) < 1e-9)
}

@Test func subframeSequenceReturnsTheOriginalRecordsWhenNotSubdividing() {
    let records = [record(latitude: 0), record(latitude: 1)]
    #expect(TelemetryRecord.subframeSequence(records, subframesPerRecord: 1).count == 2)
    #expect(TelemetryRecord.subframeSequence([], subframesPerRecord: 3).isEmpty)
}
