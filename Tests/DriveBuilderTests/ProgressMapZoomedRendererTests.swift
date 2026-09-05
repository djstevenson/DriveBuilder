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
        speedLimit: 30,
        file: nil,
        source: "test")
}

// MARK: - OSGB

@Test func gridPointsMatchThePerlModule() {
    // Reference values from Geo::Coordinates::OSGB's ll_to_grid; the small
    // Helmert transformation agrees with its OSTN-based results to ~2 m,
    // which is a pixel at the map's 2 m/px.
    let references: [(lat: Double, lon: Double, easting: Double, northing: Double)] = [
        (51.501, -0.142, 529_059.684, 179_643.096),
        (52.2, 0.12, 544_980.776, 257_868.435),
        (51.4779, -0.0015, 538_881.067, 177_331.344),
        (53.5, -2.25, 383_513.657, 400_394.329),
    ]
    for reference in references {
        let point = OSGB.gridPoint(latitude: reference.lat, longitude: reference.lon)
        #expect(abs(point.easting - reference.easting) < 2.5)
        #expect(abs(point.northing - reference.northing) < 2.5)
    }
}

// MARK: - Frames

@Test func threeFramesPerRecordAfterTheFirst() {
    let start = Date(timeIntervalSince1970: 1_775_000_000)
    let renderer = ProgressMapZoomedRenderer(
        records: (0..<4).map {
            record(
                latitude: 51.0 + Double($0) * 0.0001, longitude: -1.5,
                timestamp: start.addingTimeInterval(Double($0) * 0.1))
        },
        tileRenderer: StubTileRenderer(dot: OSGB.GridPoint(easting: 0, northing: 0)))

    let frames = renderer.frames
    #expect(frames.count == 10)
    // Frames 0, 3, 6, 9 are the records themselves; the pairs between are
    // interpolated thirds.
    let first = OSGB.gridPoint(latitude: 51.0, longitude: -1.5)
    #expect(abs(frames[0].grid.northing - first.northing) < 0.001)
    let third = frames[1].grid.northing - frames[0].grid.northing
    #expect(abs((frames[2].grid.northing - frames[1].grid.northing) - third) < 0.01)
}

// MARK: - Tiles

@Test func tileIsReusedUntilTheCarNearsItsEdge() {
    let renderer = ProgressMapZoomedRenderer(
        records: [],
        pixelSize: 420,
        tileSizeMetres: 3_000,
        tileRenderer: StubTileRenderer(dot: OSGB.GridPoint(easting: 0, northing: 0)))
    // Margin is half the window in metres: 210 px * 2 m/px = 420 m.
    #expect(renderer.tileMarginMetres == 420)

    let origin = OSGB.GridPoint(easting: 450_000, northing: 130_000)
    let nearEdge = OSGB.GridPoint(easting: 451_000, northing: 130_000)
    let frames = [
        ProgressMapZoomedRenderer.Frame(grid: origin, heading: 0),
        ProgressMapZoomedRenderer.Frame(
            grid: OSGB.GridPoint(easting: 450_500, northing: 130_000), heading: 0),
        // 1000 m east still clears the margin (edge at +1500); 1200 m does not.
        ProgressMapZoomedRenderer.Frame(grid: nearEdge, heading: 0),
        ProgressMapZoomedRenderer.Frame(
            grid: OSGB.GridPoint(easting: 451_200, northing: 130_000), heading: 0),
    ]

    let (tiles, frameTile) = renderer.tileSchedule(for: frames)
    #expect(tiles.count == 2)
    #expect(frameTile == [0, 0, 0, 1])
    // The second tile is centred on the frame that triggered it.
    #expect(tiles[1].minEasting == 451_200 - 1_500)
    #expect(tiles[1].maxNorthing == 130_000 + 1_500)
}

// MARK: - Drawing

/// Paints a white tile with an 8px red dot at a fixed grid position, so
/// frame tests can check where map features land in the output.
private struct StubTileRenderer: MapTileRenderer {
    let dot: OSGB.GridPoint

    func renderMap(_ bbox: MapBBox) throws -> CGImage {
        let context = try LayerCompositor.bitmapContext(width: bbox.width, height: bbox.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bbox.width, height: bbox.height))

        let metresPerPixel = (bbox.maxEasting - bbox.minEasting) / Double(bbox.width)
        let x = (dot.easting - bbox.minEasting) / metresPerPixel
        let yFromTop = (bbox.maxNorthing - dot.northing) / metresPerPixel
        let y = Double(bbox.height) - yFromTop
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))

        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return image
    }
}

private func redCentroid(_ frame: NSBitmapImageRep) -> CGPoint? {
    var sumX = 0.0
    var sumY = 0.0
    var count = 0
    for y in 0..<frame.pixelsHigh {
        for x in 0..<frame.pixelsWide {
            guard let colour = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.redComponent > 0.8,
                colour.greenComponent < 0.2,
                colour.blueComponent < 0.2
            else { continue }
            sumX += Double(x)
            sumY += Double(y)
            count += 1
        }
    }
    guard count > 0 else { return nil }
    return CGPoint(x: sumX / Double(count), y: sumY / Double(count))
}

@Test func mapWindowIsCentredOnTheCar() throws {
    let car = record(latitude: 51.0, longitude: -1.5)
    let carGrid = OSGB.gridPoint(latitude: car.latitude, longitude: car.longitude)

    // A map feature 50 m east and 30 m north of the car should land 25 px
    // right of and 15 px above the frame centre at 2 m/px.
    let dot = OSGB.GridPoint(
        easting: carGrid.easting + 50, northing: carGrid.northing + 30)
    let renderer = ProgressMapZoomedRenderer(
        records: [car],
        pixelSize: 420,
        tileSizeMetres: 3_000,
        tileRenderer: StubTileRenderer(dot: dot))

    let frames = renderer.frames
    let (tiles, frameTile) = renderer.tileSchedule(for: frames)
    #expect(tiles.count == 1)

    let tileImage = try renderer.tileRenderer.renderMap(tiles[0])
    let canvas = try SVGRasterizer.blankBitmap(width: 420, height: 420)
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    renderer.draw(
        frames[0], tile: tileImage, bbox: tiles[frameTile[0]],
        car: try renderer.carImage(), into: context.cgContext)

    let centroid = try #require(redCentroid(canvas))
    #expect(abs(centroid.x - 235) < 2)
    #expect(abs(centroid.y - 195) < 2)
}
