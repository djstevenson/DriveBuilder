import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(altitudeMetres: Double) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: 0,
        longitude: 0,
        altitude: altitudeMetres,
        speed: 0,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test")
}

@Test func metresConvertToWholeFeetLikeThePerlRounding() {
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 30.48)) == 100)
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 100)) == 328)
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 0)) == 0)
    // Perl's int() truncates toward zero: int(-82.68 + 0.5) == -82.
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: -25.2)) == -82)
}

@Test func journeyAltitudesAreDeduplicatedToWholeFeet() {
    let renderer = AltitudeRenderer(records: [
        record(altitudeMetres: 30.48),
        record(altitudeMetres: 30.50),
        record(altitudeMetres: 100),
    ])
    #expect(renderer.altitudes == [100, 328])
}

@Test func artworkLoadsOneLabelPerAltitude() throws {
    let artwork = try AltitudeRenderer.Artwork(pixelSize: 420, altitudes: [0, 100, 328])
    #expect(artwork.labels.count == 3)
}

/// The label band sits below the mountain: the SVG mountain bottoms out at
/// viewBox y=90 and the text baseline is y=105, so in a 420px frame the text
/// ink lives between rows 315 and 368 where no other artwork is drawn.
@Test func frameShowsTheLabelBelowTheMountain() throws {
    let renderer = AltitudeRenderer(records: [])
    let artwork = try AltitudeRenderer.Artwork(pixelSize: 420, altitudes: [328])
    let frame = try renderer.frame(for: record(altitudeMetres: 100), artwork: artwork)

    var inkPixels = 0
    for y in 316..<368 {
        for x in 0..<420 {
            guard let colour = frame.colorAt(x: x, y: y),
                colour.alphaComponent > 0.5
            else { continue }
            inkPixels += 1
        }
    }
    #expect(inkPixels > 200)
}

@Test func altitudeFrameKeepsSizeAndFillsCornersWithTheBackdrop() throws {
    let renderer = AltitudeRenderer(records: [], pixelSize: 200)
    let artwork = try AltitudeRenderer.Artwork(pixelSize: 200, altitudes: [50])
    let frame = try renderer.frame(for: record(altitudeMetres: 15.24), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(abs(corner.alphaComponent - 0.6) < 0.01)
    #expect(corner.redComponent < 0.01)
}
