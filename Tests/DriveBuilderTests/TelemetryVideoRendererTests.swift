import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(
    latitude: Double, longitude: Double, timestamp: Date
) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: 100,
        speed: 50,
        heading: 45,
        accelForward: 0.1,
        accelLateral: -0.1,
        speedLimit: 40,
        file: nil,
        source: "test")
}

private func testRecords() -> [TelemetryRecord] {
    (0..<3).map {
        record(
            latitude: 51.0 + Double($0) * 0.001,
            longitude: -1.5 + Double($0) * 0.001,
            timestamp: Date(timeIntervalSinceReferenceDate: Double($0)))
    }
}

/// A plain white map, so map cells are solidly opaque and easy to tell from
/// the transparent gaps.
private struct WhiteTileRenderer: MapTileRenderer {
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

/// A renderer at a small test scale: 60 px dials and 138 px maps keep the
/// default 18 px gap, on a 138x450 canvas.
private func testRenderer() -> TelemetryVideoRenderer {
    var renderer = TelemetryVideoRenderer(
        records: testRecords(),
        dialPixelSize: 60,
        mapPixelSize: 138,
        tileRenderer: WhiteTileRenderer())
    // The default 30 km tile would be thousands of pixels at this scale.
    renderer.progressMapZoomed.tileSizeMetres = 2_000
    return renderer
}

@Test func layoutMatchesTheFFmpegGraphAtDefaultSizes() {
    let renderer = TelemetryVideoRenderer(records: [], tileRenderer: WhiteTileRenderer())
    #expect(renderer.gap == 18)
    #expect(renderer.width == 708)
    #expect(renderer.height == 2160)
}

@Test func layoutDerivesTheGapFromTheTwoEdgeLengths() {
    let renderer = testRenderer()
    #expect(renderer.gap == 18)
    #expect(renderer.width == 138)
    #expect(renderer.height == 450)
}

@Test func artworkIsLimitedToTheRequestedFrames() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork(frameCount: 1)
    #expect(artwork.zoomedFrames.count == 1)
    #expect(artwork.zoomedFrameTile.count == 1)
}

private func compositedFrame(
    _ renderer: TelemetryVideoRenderer, frameIndex: Int, artwork: TelemetryVideoRenderer.Artwork
) throws -> NSBitmapImageRep {
    let canvas = try SVGRasterizer.blankBitmap(width: renderer.width, height: renderer.height)
    try SVGRasterizer.withGraphicsContext(over: canvas) { context in
        renderer.draw(frameIndex: frameIndex, into: context.cgContext, artwork: artwork)
    }
    return canvas
}

private func alpha(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    frame.colorAt(x: x, y: y)?.alphaComponent ?? -1
}

private func isOpaqueWhite(_ colour: NSColor?) -> Bool {
    guard let colour = colour?.usingColorSpace(.deviceRGB) else { return false }
    return colour.alphaComponent > 0.9 && colour.redComponent > 0.9
        && colour.greenComponent > 0.9 && colour.blueComponent > 0.9
}

@Test func cellsLandWhereTheFFmpegOverlaysPutThem() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork(frameCount: renderer.records.count)
    let frame = try compositedFrame(renderer, frameIndex: 0, artwork: artwork)

    // Dial cells: each corner shows its dial's 0.6-alpha black backdrop.
    // Speedo (0, 0), g-force (78, 0), compass (0, 78), altitude (78, 78).
    for (x, y) in [(3, 3), (81, 3), (3, 81), (81, 81)] {
        let backdrop = try #require(frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        #expect(abs(backdrop.alphaComponent - 0.6) < 0.05)
        #expect(backdrop.redComponent < 0.1)
    }

    // Map cells: the white base map fills the zoomed map at y 156 and the
    // overview map at y 312.
    #expect(isOpaqueWhite(frame.colorAt(x: 10, y: 160)))
    #expect(isOpaqueWhite(frame.colorAt(x: 10, y: 320)))
}

@Test func gapsBetweenCellsStayTransparent() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork(frameCount: renderer.records.count)
    let frame = try compositedFrame(renderer, frameIndex: 0, artwork: artwork)

    // Column gap between the dials, x 60-77.
    #expect(alpha(frame, 68, 3) == 0)
    // Row gap between the dial grid and the zoomed map, y 138-155. The
    // zoomed map's tile is far bigger than its cell, so ink here means the
    // cell clipping has broken.
    #expect(alpha(frame, 10, 145) == 0)
    #expect(alpha(frame, 68, 145) == 0)
    // Row gap between the two maps, y 294-311.
    #expect(alpha(frame, 10, 300) == 0)
}
