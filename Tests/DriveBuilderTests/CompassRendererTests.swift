import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(heading: Double) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: 0,
        longitude: 0,
        altitude: 0,
        speed: 0,
        heading: heading,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test")
}

/// Counts red needle pixels in each half of the frame. The dial artwork has no
/// red, so any red pixel belongs to the needle.
private func redCounts(_ frame: NSBitmapImageRep) -> (top: Int, bottom: Int, left: Int, right: Int)
{
    let size = frame.pixelsWide
    var counts = (top: 0, bottom: 0, left: 0, right: 0)
    for y in 0..<size {
        for x in 0..<size {
            guard let colour = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.5,
                colour.redComponent > 0.6,
                colour.greenComponent < 0.35
            else { continue }
            if y < size / 2 { counts.top += 1 } else { counts.bottom += 1 }
            if x < size / 2 { counts.left += 1 } else { counts.right += 1 }
        }
    }
    return counts
}

@Test func needlePointsNorthAtHeadingZero() throws {
    let renderer = CompassRenderer(records: [])
    let artwork = try CompassRenderer.Artwork(pixelSize: 420)
    let counts = redCounts(try renderer.frame(for: record(heading: 0), artwork: artwork))

    #expect(counts.top > 200)
    #expect(counts.top > counts.bottom * 5)
}

@Test func needleRotatesClockwiseToEastAtHeadingNinety() throws {
    let renderer = CompassRenderer(records: [])
    let artwork = try CompassRenderer.Artwork(pixelSize: 420)
    let counts = redCounts(try renderer.frame(for: record(heading: 90), artwork: artwork))

    #expect(counts.right > 200)
    #expect(counts.right > counts.left * 5)
}

@Test func compositedFrameKeepsSizeAndFillsCornersWithTheBackdrop() throws {
    let renderer = CompassRenderer(records: [], pixelSize: 200)
    let artwork = try CompassRenderer.Artwork(pixelSize: 200)
    let frame = try renderer.frame(for: record(heading: 45), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(abs(corner.alphaComponent - 0.6) < 0.01)
    #expect(corner.redComponent < 0.01)
}
