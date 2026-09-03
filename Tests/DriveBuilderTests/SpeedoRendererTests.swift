import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(mph: Double, limit: Int?) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: 0,
        longitude: 0,
        altitude: 0,
        speed: mph / SpeedoRenderer.mphPerKPH,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: limit,
        file: nil,
        source: "test")
}

@Test func needleAngleMatchesDialCalibration() {
    #expect(SpeedoRenderer.angle(forMPH: 40) == 0)
    #expect(SpeedoRenderer.angle(forMPH: 0) == -130)
    #expect(SpeedoRenderer.angle(forMPH: 80) == 130)
}

@Test func indicatedSpeedIsClampedToTheLimit() {
    #expect(abs(SpeedoRenderer.indicatedMPH(for: record(mph: 30, limit: 50)) - 30) < 0.001)
    #expect(abs(SpeedoRenderer.indicatedMPH(for: record(mph: 70, limit: 50)) - 50) < 0.001)
}

@Test func missingSpeedLimitFallsBackToTheAssumedLimit() {
    let assumed = Double(SpeedoRenderer.assumedSpeedLimit)
    #expect(abs(SpeedoRenderer.indicatedMPH(for: record(mph: 99, limit: nil)) - assumed) < 0.001)
}

/// Counts red needle pixels in the lower-left and lower-right quadrants.
private func lowerQuadrantRedCounts(_ frame: NSBitmapImageRep) -> (left: Int, right: Int) {
    let size = frame.pixelsWide
    var left = 0
    var right = 0
    for y in (size / 2)..<size {
        for x in 0..<size {
            guard let colour = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.5,
                colour.redComponent > 0.6,
                colour.greenComponent < 0.35
            else { continue }
            if x < size / 2 { left += 1 } else { right += 1 }
        }
    }
    return (left, right)
}

@Test func needleRotatesClockwiseWithIncreasingSpeed() throws {
    let renderer = SpeedoRenderer(records: [])
    let artwork = try SpeedoRenderer.Artwork(pixelSize: 420, speedLimits: [40, 80])

    // A 40 mph limit parks the marker straight up, out of both lower quadrants.
    let slow = try renderer.frame(for: record(mph: 0, limit: 40), artwork: artwork)
    let fast = try renderer.frame(for: record(mph: 80, limit: 80), artwork: artwork)

    let slowCounts = lowerQuadrantRedCounts(slow)
    let fastCounts = lowerQuadrantRedCounts(fast)

    // The needle hub straddles the centre, so each quadrant always picks up a
    // few pixels; what matters is which side the blade sweeps into.
    #expect(slowCounts.left > 200)
    #expect(slowCounts.left > slowCounts.right * 5)
    #expect(fastCounts.right > 200)
    #expect(fastCounts.right > fastCounts.left * 5)
}

@Test func compositedFrameKeepsRequestedSizeAndFillsCornersWithTheBackdrop() throws {
    let renderer = SpeedoRenderer(records: [], pixelSize: 200)
    let artwork = try SpeedoRenderer.Artwork(pixelSize: 200, speedLimits: [50])
    let frame = try renderer.frame(for: record(mph: 30, limit: 50), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(abs(corner.alphaComponent - 0.6) < 0.01)
    #expect(corner.redComponent < 0.01)
}
