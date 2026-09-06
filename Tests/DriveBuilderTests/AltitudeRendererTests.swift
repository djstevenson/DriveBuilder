import AppKit
import CoreText
import Foundation
import Testing

@testable import DriveBuilder

private func record(
    latitude: Double = 0, longitude: Double = 0, altitudeMetres: Double = 0,
    odometerMetres: Double = 0, timestamp: Date = .distantPast
) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: altitudeMetres,
        speed: 0,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test",
        odometer: odometerMetres)
}

@Test func metresConvertToWholeFeetLikeThePerlRounding() {
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 30.48)) == 100)
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 100)) == 328)
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: 0)) == 0)
    // Perl's int() truncates toward zero: int(-82.68 + 0.5) == -82.
    #expect(AltitudeRenderer.altitudeFeet(for: record(altitudeMetres: -25.2)) == -82)
}

@Test func rowTextsFormatLatitudeLongitudeToFourDecimalPlacesWithAHemisphereLetterInsteadOfASign() {
    let texts = AltitudeRenderer.rowTexts(
        for: record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100, odometerMetres: 0),
        startTimestamp: .distantPast)
    #expect(texts == ["51.5000N", "1.2500W", "328 ft", "0.0 mi", "00:00:00"])

    let southAndEast = AltitudeRenderer.rowTexts(
        for: record(latitude: -33.8, longitude: 151.2, altitudeMetres: 0),
        startTimestamp: .distantPast)
    #expect(southAndEast[0] == "33.8000S")
    #expect(southAndEast[1] == "151.2000E")
}

@Test func odometerTextConvertsMetresToMilesToOneDecimalPlace() {
    // 1 mile = 1609.344 m exactly, so this is exactly 10.0 mi rather than
    // something that depends on rounding.
    let texts = AltitudeRenderer.rowTexts(
        for: record(odometerMetres: 16_093.44), startTimestamp: .distantPast)
    #expect(texts[3] == "10.0 mi")
}

@Test func elapsedTextFormatsHoursMinutesAndSecondsWithoutFractions() {
    #expect(AltitudeRenderer.elapsedText(seconds: 0) == "00:00:00")
    #expect(AltitudeRenderer.elapsedText(seconds: 59.9) == "00:00:59")
    #expect(AltitudeRenderer.elapsedText(seconds: 60) == "00:01:00")
    #expect(AltitudeRenderer.elapsedText(seconds: 3661) == "01:01:01")
    // 1 hour, 11 minutes, 40 seconds.
    #expect(AltitudeRenderer.elapsedText(seconds: 4300) == "01:11:40")
}

@Test func elapsedTextCountsFromTheJourneysStartTimestamp() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let texts = AltitudeRenderer.rowTexts(
        for: record(timestamp: start.addingTimeInterval(3725)), startTimestamp: start)
    #expect(texts[4] == "01:02:05")
}

/// Box geometry is fixed regardless of content - the same margin either
/// side of the frame every time - so it's the font that has to adapt.
@Test func boxGeometryIsFixedRegardlessOfContent() {
    #expect(AltitudeRenderer.boxLeft == AltitudeRenderer.boxMargin)
    #expect(AltitudeRenderer.boxWidth == 120 - 2 * AltitudeRenderer.boxMargin)
}

@Test func fontNeverExceedsTheCeiling() {
    // "LAT ##.####" is 10-11 characters even for the shortest realistic
    // values, which already doesn't fit the fixed-width box at 26pt - so in
    // practice this format almost always shrinks. What matters is that it
    // never shrinks past `minFontSize` or grows past the ceiling.
    let artwork = AltitudeRenderer.Artwork(
        records: [record(latitude: 0, longitude: 0, altitudeMetres: 0)])
    #expect(artwork.font.pointSize <= AltitudeRenderer.fontSize)
    #expect(artwork.font.pointSize >= AltitudeRenderer.minFontSize)
}

/// A journey with a long formatted value (a large negative longitude)
/// wouldn't fit the fixed-width box at the ceiling size, so the font
/// shrinks - by exactly enough that the widest candidate still fits, since
/// ink width scales linearly with point size.
@Test func fontShrinksJustEnoughForTheJourneysWidestValueToFit() {
    let widestRecord = record(latitude: 51.5, longitude: -179.9999, altitudeMetres: 100)
    let artwork = AltitudeRenderer.Artwork(records: [widestRecord])
    #expect(artwork.font.pointSize < AltitudeRenderer.fontSize)

    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: AltitudeRenderer.longitudeText(widestRecord),
            attributes: [.font: artwork.font]))
    let width = Double(CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
    let availableWidth = AltitudeRenderer.boxWidth - 2 * AltitudeRenderer.textPadding
    #expect(width <= availableWidth + 0.5)
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

/// Away from the text boxes, the frame shows the same 0.6-alpha black
/// backdrop as the speedo, g-force, and compass dials, rather than staying
/// fully transparent.
@Test func frameShowsTheDimmedBackdropAwayFromTheBoxes() throws {
    let renderer = AltitudeRenderer(records: [], pixelSize: 420)
    let artwork = AltitudeRenderer.Artwork(
        records: [record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100)])
    let frame = try renderer.frame(
        for: record(latitude: 51.5, longitude: -1.25, altitudeMetres: 100), artwork: artwork)

    for (x, y) in [(2, 2), (415, 2), (2, 415), (415, 415), (415, 357)] {
        let colour = try #require(frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        #expect(abs(colour.alphaComponent - 0.6) < 0.01)
        #expect(colour.redComponent < 0.01)
    }
}
