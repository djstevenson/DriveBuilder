import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(limit: Int?) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: 0,
        longitude: 0,
        altitude: 0,
        speed: 0,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: limit,
        file: nil,
        source: "test")
}

@Test func missingSpeedLimitFallsBackToAssumedLimit() {
    #expect(LimitRenderer.speedLimit(for: record(limit: nil)) == LimitRenderer.assumedSpeedLimit)
    #expect(LimitRenderer.speedLimit(for: record(limit: 30)) == 30)
}

@Test func journeyLimitsAlwaysIncludeTheAssumedLimit() {
    let renderer = LimitRenderer(records: [record(limit: 30), record(limit: 70)])
    #expect(renderer.speedLimits == [30, 70, LimitRenderer.assumedSpeedLimit])
}

@Test func artworkLoadsOneSignPerLimit() throws {
    let artwork = try LimitRenderer.Artwork(pixelSize: 420, speedLimits: [20, 30, 40, 50, 60, 70])
    #expect(artwork.signs.count == 6)
}

@Test func artworkFailsUpFrontForALimitWithNoBundledSign() {
    #expect(throws: BundledArtworkError.self) {
        try LimitRenderer.Artwork(pixelSize: 420, speedLimits: [55])
    }
}

/// The sign is a white disc with a red ring; sample the centre and the ring.
@Test func frameShowsTheSignForTheRecordsLimit() throws {
    let renderer = LimitRenderer(records: [], pixelSize: 420)
    let artwork = try LimitRenderer.Artwork(pixelSize: 420, speedLimits: [30])
    let frame = try renderer.frame(for: record(limit: 30), artwork: artwork)

    #expect(frame.pixelsWide == 420)
    #expect(frame.pixelsHigh == 420)

    // Corners are outside the circular sign and stay transparent.
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(corner.alphaComponent < 0.01)

    // The ring sits at the sign's edge on the horizontal centre line.
    let ring = try #require(frame.colorAt(x: 35, y: 210)?.usingColorSpace(.deviceRGB))
    #expect(ring.alphaComponent > 0.5)
    #expect(ring.redComponent > 0.6)
    #expect(ring.greenComponent < 0.35)
}
