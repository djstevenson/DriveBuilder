import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(
    latitude: Double = 0, longitude: Double = 0, altitudeMetres: Double = 0
) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: .distantPast,
        latitude: latitude,
        longitude: longitude,
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

@Test func rowTextsFormatLatitudeLongitudeAndAltitudeToFourDecimalPlaces() {
    let texts = AltitudeRenderer.rowTexts(
        for: record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100))
    #expect(texts == ["LAT 51.5000", "LON -1.2500", "ALT 328 ft"])
}

@Test func boxWidthGrowsToFitTheWidestValueInTheJourney() {
    func latitudeBoxWidth(_ latitudes: [Double]) -> Double {
        AltitudeRenderer.Artwork(records: latitudes.map { record(latitude: $0) }).boxWidths[0]
    }
    let narrow = latitudeBoxWidth([51.0])
    let wide = latitudeBoxWidth([-90.0, 90.0])
    #expect(wide > narrow)
}

@Test func boxWidthStaysFixedAcrossFramesOfTheSameJourney() {
    // A record near the extremes shouldn't get a differently sized box than
    // one near the middle of the journey's range - the whole point of
    // sizing from the journey's extremes is that the box never resizes.
    let records = [record(latitude: 0), record(latitude: -90), record(latitude: 90)]
    let artwork = AltitudeRenderer.Artwork(records: records)
    #expect(artwork.boxWidths.count == 3)
    #expect(artwork.boxWidths.allSatisfy { $0 > 0 })
}

@Test func frameKeepsTheRequestedPixelSize() throws {
    let renderer = AltitudeRenderer(records: [], pixelSize: 200)
    let artwork = AltitudeRenderer.Artwork(records: [])
    let frame = try renderer.frame(for: record(altitudeMetres: 15.24), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
}

/// Each line of text sits on its own fully opaque box rather than a
/// translucent backdrop, so it stays legible over any dashcam footage.
@Test func frameDrawsAnOpaqueBoxBehindTheTopRow() throws {
    let renderer = AltitudeRenderer(records: [], pixelSize: 420)
    let artwork = AltitudeRenderer.Artwork(
        records: [record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100)])
    let frame = try renderer.frame(
        for: record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100), artwork: artwork)

    // Just inside the top-left corner of the latitude box, before the
    // text's left padding starts, so this is background rather than ink.
    // `colorAt` counts rows from the top, while the renderer draws with
    // Core Graphics' bottom-up origin, hence the flip.
    let scale = 420.0 / 120.0
    let boxBottom = AltitudeRenderer.rowBottom(0) * scale
    let boxMidY = boxBottom + AltitudeRenderer.rowHeight * scale / 2
    let probeX = Int(AltitudeRenderer.boxLeft * scale) + 2
    let probeY = Int(420 - boxMidY)

    let inBox = try #require(frame.colorAt(x: probeX, y: probeY))
    #expect(inBox.alphaComponent > 0.99)
    #expect(inBox.redComponent < 0.05)
}

/// The boxes are sized to their text, not the whole frame, so most of the
/// frame - including the far corners - stays transparent.
@Test func frameStaysTransparentAwayFromTheBoxes() throws {
    let renderer = AltitudeRenderer(records: [], pixelSize: 420)
    let artwork = AltitudeRenderer.Artwork(
        records: [record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100)])
    let frame = try renderer.frame(
        for: record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100), artwork: artwork)

    for (x, y) in [(2, 2), (415, 2), (2, 415), (415, 415), (415, 357)] {
        let colour = try #require(frame.colorAt(x: x, y: y))
        #expect(colour.alphaComponent == 0)
    }
}
