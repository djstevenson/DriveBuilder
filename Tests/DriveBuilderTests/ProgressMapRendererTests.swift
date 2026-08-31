import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(
    latitude: Double, longitude: Double, heading: Double = 0, timestamp: Date = .distantPast
) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: 0,
        speed: 0,
        heading: heading,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test")
}

/// A plain white map, so the only coloured pixels in a frame are the track's.
private struct BlankTileRenderer: MapTileRenderer {
    func renderMap(_ bbox: MapBBox) throws -> CGImage {
        let context = try LayerCompositor.bitmapContext(width: bbox.width, height: bbox.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bbox.width, height: bbox.height))
        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return image
    }
}

@Test func gridPointsMapToPixelsTopLeftDown() {
    let bbox = MapBBox(
        minEasting: 1_000, minNorthing: 2_000, maxEasting: 1_840, maxNorthing: 2_840,
        width: 420, height: 420)
    // 840 m over 420 px is 2 m/px; the north-west corner is pixel (0, 0).
    #expect(
        bbox.pixelPosition(of: OSGB.GridPoint(easting: 1_000, northing: 2_840)) == CGPoint(x: 0, y: 0))
    #expect(
        bbox.pixelPosition(of: OSGB.GridPoint(easting: 1_420, northing: 2_420))
            == CGPoint(x: 210, y: 210))
    #expect(
        bbox.pixelPosition(of: OSGB.GridPoint(easting: 1_002, northing: 2_836))
            == CGPoint(x: 1, y: 2))
}

@Test func routeBBoxIsPaddedSquareAndCentred() {
    let a = record(latitude: 51.0, longitude: -1.5)
    let b = record(latitude: 51.01, longitude: -1.48)
    let renderer = ProgressMapRenderer(
        records: [a, b], pixelSize: 420, tileRenderer: BlankTileRenderer())

    let gridA = OSGB.gridPoint(latitude: a.latitude, longitude: a.longitude)
    let gridB = OSGB.gridPoint(latitude: b.latitude, longitude: b.longitude)
    let rawWidth = abs(gridA.easting - gridB.easting)
    let rawHeight = abs(gridA.northing - gridB.northing)

    let bbox = renderer.routeBBox
    let side = bbox.maxEasting - bbox.minEasting
    // Square, output-sized, and as long as the padded longer dimension.
    #expect(abs(side - (bbox.maxNorthing - bbox.minNorthing)) < 0.001)
    #expect(abs(side - max(rawWidth, rawHeight) * 1.2) < 0.001)
    #expect(bbox.width == 420)
    #expect(bbox.height == 420)
    // Both endpoints stay inside with at least the 10% margin.
    #expect(bbox.minEasting <= min(gridA.easting, gridB.easting) - 0.1 * rawWidth + 0.001)
    #expect(bbox.maxNorthing >= max(gridA.northing, gridB.northing) + 0.1 * rawHeight - 0.001)
}

/// The track colour is #ff4d1a, the only orange in a frame on a white map
/// (the casing is a much darker #330d00).
private func isTrackOrange(_ colour: NSColor?) -> Bool {
    guard let colour = colour?.usingColorSpace(.deviceRGB) else { return false }
    return colour.redComponent > 0.8 && colour.greenComponent < 0.45
        && colour.blueComponent < 0.35
}

private func orangeCentroid(_ frame: NSBitmapImageRep) -> CGPoint? {
    var sumX = 0.0
    var sumY = 0.0
    var count = 0
    for y in 0..<frame.pixelsHigh {
        for x in 0..<frame.pixelsWide {
            guard isTrackOrange(frame.colorAt(x: x, y: y)) else { continue }
            sumX += Double(x)
            sumY += Double(y)
            count += 1
        }
    }
    guard count > 0 else { return nil }
    return CGPoint(x: sumX / Double(count), y: sumY / Double(count))
}

@Test func markerIsDrawnAtTheCurrentPosition() throws {
    let start = record(
        latitude: 51.0, longitude: -1.5, timestamp: Date(timeIntervalSinceReferenceDate: 0))
    let end = record(
        latitude: 51.01, longitude: -1.48, timestamp: Date(timeIntervalSinceReferenceDate: 1))
    let renderer = ProgressMapRenderer(
        records: [start, end], pixelSize: 420, tileRenderer: BlankTileRenderer())
    let artwork = try renderer.makeArtwork()

    // On the first record no route has been travelled yet, so the frame's
    // only orange ink is the circular marker, centred on the position.
    let frame = try renderer.frame(for: start, artwork: artwork)
    let centroid = try #require(orangeCentroid(frame))
    let expected = artwork.bbox.pixelPosition(
        of: OSGB.gridPoint(latitude: start.latitude, longitude: start.longitude))

    #expect(abs(centroid.x - expected.x) < 2)
    #expect(abs(centroid.y - expected.y) < 2)
}

/// The arrow is pure black; the only other dark ink (the #330d00 casing)
/// never appears this close to the marker's centre.
private func isArrowBlack(_ colour: NSColor?) -> Bool {
    guard let colour = colour?.usingColorSpace(.deviceRGB) else { return false }
    return colour.redComponent < 0.25 && colour.greenComponent < 0.25
        && colour.blueComponent < 0.25
}

@Test func headingArrowPointsAlongTheHeading() throws {
    let start = record(
        latitude: 51.0, longitude: -1.5, heading: 90,
        timestamp: Date(timeIntervalSinceReferenceDate: 0))
    let end = record(
        latitude: 51.01, longitude: -1.48, heading: 90,
        timestamp: Date(timeIntervalSinceReferenceDate: 1))
    let renderer = ProgressMapRenderer(
        records: [start, end], pixelSize: 420, tileRenderer: BlankTileRenderer())
    let artwork = try renderer.makeArtwork()

    let frame = try renderer.frame(for: start, artwork: artwork)
    let centre = artwork.bbox.pixelPosition(
        of: OSGB.gridPoint(latitude: start.latitude, longitude: start.longitude))
    let x = Int(centre.x.rounded())
    let y = Int(centre.y.rounded())

    // Heading 90 points the arrow east: black ink at the centre and towards
    // the tip on the right (sampled short of the tip, where the arrow is
    // still solidly wide), plain marker orange behind the tail on the left.
    #expect(isArrowBlack(frame.colorAt(x: x, y: y)))
    #expect(isArrowBlack(frame.colorAt(x: x + 4, y: y)))
    #expect(isTrackOrange(frame.colorAt(x: x - 8, y: y)))
}

@Test func travelledRouteIsStrokedOnlyUpToTheCurrentRecord() throws {
    let records = [
        record(latitude: 51.0, longitude: -1.5, timestamp: Date(timeIntervalSinceReferenceDate: 0)),
        record(
            latitude: 51.01, longitude: -1.49, timestamp: Date(timeIntervalSinceReferenceDate: 1)),
        record(
            latitude: 51.02, longitude: -1.48, timestamp: Date(timeIntervalSinceReferenceDate: 2)),
    ]
    let renderer = ProgressMapRenderer(
        records: records, pixelSize: 420, tileRenderer: BlankTileRenderer())
    let artwork = try renderer.makeArtwork()

    let frame = try renderer.frame(for: records[1], artwork: artwork)
    let position = { (record: TelemetryRecord) in
        artwork.bbox.pixelPosition(
            of: OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude))
    }

    // The travelled leg is stroked in orange from the start...
    let start = position(records[0])
    #expect(isTrackOrange(frame.colorAt(x: Int(start.x.rounded()), y: Int(start.y.rounded()))))
    // ...but the leg not yet travelled is untouched map.
    let end = position(records[2])
    #expect(!isTrackOrange(frame.colorAt(x: Int(end.x.rounded()), y: Int(end.y.rounded()))))
}
