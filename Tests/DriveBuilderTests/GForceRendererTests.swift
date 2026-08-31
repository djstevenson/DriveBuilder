import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(forward: Double?, lateral: Double?) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: 0,
        longitude: 0,
        altitude: 0,
        speed: 0,
        heading: 0,
        accelForward: forward,
        accelLateral: lateral,
        speedLimit: nil,
        file: nil,
        source: "test")
}

@Test func forceIsClampedToTheDialRange() {
    let clamped = GForceRenderer.clampedForce(for: record(forward: 4, lateral: 3))
    #expect(abs(clamped.lateral - 0.6) < 0.001)
    #expect(abs(clamped.longitudinal - 0.8) < 0.001)

    let gentle = GForceRenderer.clampedForce(for: record(forward: 0.3, lateral: -0.4))
    #expect(gentle.lateral == -0.4)
    #expect(gentle.longitudinal == 0.3)
}

@Test func missingAccelerometerDataRestsAtTheCentre() {
    let position = GForceRenderer.markerPosition(
        for: record(forward: nil, lateral: nil), pixelSize: 420)
    #expect(position == CGPoint(x: 210, y: 210))
}

@Test func markerShowsSensedForceNotRawAcceleration() {
    // Braking at half the range: the driver is thrown forward, so the marker
    // sits above centre; the dial edge is 175px out at this size.
    let braking = GForceRenderer.markerPosition(
        for: record(forward: -0.5, lateral: nil), pixelSize: 420)
    #expect(braking == CGPoint(x: 210, y: 122.5))

    // Turning right throws the driver left.
    let rightTurn = GForceRenderer.markerPosition(
        for: record(forward: nil, lateral: 0.5), pixelSize: 420)
    #expect(rightTurn == CGPoint(x: 122.5, y: 210))
}

/// The dial artwork has no red, so any red pixel belongs to the marker.
private func redCentroid(_ frame: NSBitmapImageRep) -> CGPoint? {
    var sumX = 0.0
    var sumY = 0.0
    var count = 0
    for y in 0..<frame.pixelsHigh {
        for x in 0..<frame.pixelsWide {
            guard let colour = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.5,
                colour.redComponent > 0.6,
                colour.greenComponent < 0.35
            else { continue }
            sumX += Double(x)
            sumY += Double(y)
            count += 1
        }
    }
    guard count > 0 else { return nil }
    return CGPoint(x: sumX / Double(count), y: sumY / Double(count))
}

@Test func renderedMarkerLandsWhereMarkerPositionSays() throws {
    let renderer = GForceRenderer(records: [])
    let artwork = try GForceRenderer.Artwork(pixelSize: 420)
    let braking = record(forward: -0.5, lateral: nil)

    let frame = try renderer.frame(for: braking, artwork: artwork)
    let centroid = try #require(redCentroid(frame))
    let expected = GForceRenderer.markerPosition(for: braking, pixelSize: 420)

    // The centroid of the drawn disc should sit on the computed centre,
    // within antialiasing tolerance.
    #expect(abs(centroid.x - expected.x) < 2)
    #expect(abs(centroid.y - expected.y) < 2)
}

@Test func gforceFrameKeepsSizeAndTransparentCorners() throws {
    let renderer = GForceRenderer(records: [], pixelSize: 200)
    let artwork = try GForceRenderer.Artwork(pixelSize: 200)
    let frame = try renderer.frame(for: record(forward: 0, lateral: 0), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(corner.alphaComponent < 0.01)
}
