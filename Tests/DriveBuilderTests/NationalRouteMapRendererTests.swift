import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(latitude: Double, longitude: Double, timestamp: Date) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: 0,
        speed: 0,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test")
}

private func testRecords(count: Int = 5) -> [TelemetryRecord] {
    let start = Date(timeIntervalSince1970: 1_775_000_000)
    return (0..<count).map {
        record(
            latitude: 51.0 + Double($0) * 0.002,
            longitude: -1.5 + Double($0) * 0.003,
            timestamp: start.addingTimeInterval(Double($0) * 10))
    }
}

private struct SolidTileRenderer: MapTileRenderer {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    func renderMap(_ bbox: MapBBox) throws -> CGImage {
        let context = try LayerCompositor.bitmapContext(width: bbox.width, height: bbox.height)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bbox.width, height: bbox.height))
        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return image
    }
}

private func smallConfig() -> RouteMapConfig {
    var config = RouteMapConfig()
    config.width = 640
    config.height = 360
    config.framesPerSecond = 10
    return config
}

/// The detail image and bbox are now rendered by `RouteMapRenderer` and
/// injected, so tests build a real detail image the same way the merged
/// movie does: at the bbox `RouteMapRenderer` itself would use.
private func testRenderer() -> NationalRouteMapRenderer {
    let config = smallConfig()
    let detailBBox = RouteMapRenderer(
        records: testRecords(), tileRenderer: SolidTileRenderer(red: 1, green: 0, blue: 0),
        config: config
    ).mapBBox
    let detail = try! SolidTileRenderer(red: 1, green: 0, blue: 0).renderMap(detailBBox)

    return NationalRouteMapRenderer(
        records: testRecords(),
        nationalTileRenderer: SolidTileRenderer(red: 1, green: 1, blue: 1),
        detail: detail,
        detailBBox: detailBBox,
        config: config)
}

@Test func nationalBBoxCoversGreatBritainAtTheOutputAspect() {
    let bbox = testRenderer().nationalBBox

    let aspect =
        (bbox.maxEasting - bbox.minEasting) / (bbox.maxNorthing - bbox.minNorthing)
    #expect(abs(aspect - 640.0 / 360.0) < 0.001)

    #expect(bbox.minEasting <= NationalRouteMapRenderer.gbMinEasting)
    #expect(bbox.maxEasting >= NationalRouteMapRenderer.gbMaxEasting)
    #expect(bbox.minNorthing <= NationalRouteMapRenderer.gbMinNorthing)
    #expect(bbox.maxNorthing >= NationalRouteMapRenderer.gbMaxNorthing)
    #expect(bbox.width == 640)
    #expect(bbox.height == 360)
}

@Test func viewportZoomsFromTheCountryToTheRouteBox() {
    let renderer = testRenderer()
    let national = renderer.nationalBBox
    let route = renderer.detailBBox

    #expect(
        NationalRouteMapRenderer.viewport(at: 0, from: national, to: route) == national)
    #expect(
        NationalRouteMapRenderer.viewport(at: 1, from: national, to: route) == route)

    // Geometric zoom: the viewport width shrinks by the same factor over
    // each half of the move.
    let half = NationalRouteMapRenderer.viewport(at: 0.5, from: national, to: route)
    let widthAt: (MapBBox) -> Double = { $0.maxEasting - $0.minEasting }
    let firstHalfRatio = widthAt(half) / widthAt(national)
    let secondHalfRatio = widthAt(route) / widthAt(half)
    #expect(abs(firstHalfRatio - secondHalfRatio) < 0.000_001)

    // The move reads as one continuous zoom because its fixed point keeps
    // the same screen position in every frame.
    let screenPosition: (MapBBox, OSGB.GridPoint) -> CGPoint = { bbox, point in
        bbox.pixelPosition(of: point)
    }
    let ratio = widthAt(route) / widthAt(national)
    let fixedEasting =
        ((route.minEasting + route.maxEasting) / 2
            - (national.minEasting + national.maxEasting) / 2 * ratio) / (1 - ratio)
    let fixedNorthing =
        ((route.minNorthing + route.maxNorthing) / 2
            - (national.minNorthing + national.maxNorthing) / 2 * ratio) / (1 - ratio)
    let fixed = OSGB.GridPoint(easting: fixedEasting, northing: fixedNorthing)

    let atStart = screenPosition(national, fixed)
    for t in [0.25, 0.5, 0.75, 1.0] {
        let position = screenPosition(
            NationalRouteMapRenderer.viewport(at: t, from: national, to: route), fixed)
        #expect(abs(position.x - atStart.x) < 0.001)
        #expect(abs(position.y - atStart.y) < 0.001)
    }
}

@Test func frameStateFollowsTheIntroBoxZoomPhases() {
    let renderer = testRenderer()
    let national = renderer.nationalBBox
    let route = renderer.detailBBox

    // Intro: just the country, no box yet.
    let intro = renderer.frameState(at: 0)
    #expect(intro.viewport == national)
    #expect(intro.boxScale == 0)
    #expect(intro.detailAlpha == 0)

    // Hold after the pop: box settled, camera still wide.
    let holdTime =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds + 0.1
    let hold = renderer.frameState(at: holdTime)
    #expect(hold.viewport == national)
    #expect(hold.boxScale == 1)
    #expect(hold.boxAlpha == 1)
    #expect(hold.detailAlpha == 0)

    // End of the zoom and the outro: exactly the route map's area, fully
    // detailed, box gone.
    let end = renderer.frameState(at: NationalRouteMapRenderer.totalSeconds)
    #expect(end.viewport == route)
    #expect(end.detailAlpha == 1)
    #expect(end.boxAlpha == 0)
}

@Test func framePlanCoversEveryPhaseAtTheConfiguredRate() {
    let plan = testRenderer().framePlan
    #expect(plan.count == Int(NationalRouteMapRenderer.totalSeconds * 10))
    #expect(plan.first == 0)
    #expect(abs(plan[1] - 0.1) < 0.000_001)
}

@Test func introFrameIsTheNationalMapAndFinalFrameIsTheDetailMap() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork()

    func renderFrame(at time: Double) throws -> NSBitmapImageRep {
        let canvas = try SVGRasterizer.blankBitmap(width: 640, height: 360)
        let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
        renderer.draw(at: time, artwork: artwork, into: context.cgContext)
        return canvas
    }

    // The national renderer paints white, the detail renderer red.
    let intro = try renderFrame(at: 0)
    let introCentre = try #require(
        intro.colorAt(x: 320, y: 180)?.usingColorSpace(.deviceRGB))
    #expect(introCentre.redComponent > 0.95)
    #expect(introCentre.greenComponent > 0.95)
    #expect(introCentre.blueComponent > 0.95)

    let final = try renderFrame(at: NationalRouteMapRenderer.totalSeconds)
    for (x, y) in [(2, 2), (320, 180), (637, 357)] {
        let colour = try #require(final.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        #expect(colour.redComponent > 0.95)
        #expect(colour.greenComponent < 0.05)
        #expect(colour.blueComponent < 0.05)
    }
}

@Test func routeRevealsBetweenTheBoxHoldAndTheZoom() {
    let renderer = testRenderer()
    let routeStart =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds
        + NationalRouteMapRenderer.boxHoldSeconds

    // Not yet revealed just as the phase starts.
    #expect(renderer.frameState(at: routeStart).routePointCount == 0)

    // Growing partway through the reveal.
    let midReveal = renderer.frameState(
        at: routeStart + NationalRouteMapRenderer.routeRevealSeconds / 2)
    #expect(midReveal.routePointCount > 0)
    #expect(midReveal.routePointCount < 5)

    // Fully revealed by the end of the window, and still shown through the
    // hold that follows, before the zoom starts.
    let revealed = renderer.frameState(
        at: routeStart + NationalRouteMapRenderer.routeRevealSeconds)
    #expect(revealed.routePointCount == 5)
    let holdEnd = renderer.frameState(
        at: routeStart + NationalRouteMapRenderer.routeRevealSeconds
            + NationalRouteMapRenderer.routeHoldSeconds - 0.01)
    #expect(holdEnd.routePointCount == 5)
    #expect(holdEnd.boxAlpha == 1)
}

@Test func routeUndrawsBeforeTheZoomStarts() {
    let renderer = testRenderer()
    let routeStart =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds
        + NationalRouteMapRenderer.boxHoldSeconds
    let routeHoldEnd =
        routeStart + NationalRouteMapRenderer.routeRevealSeconds
        + NationalRouteMapRenderer.routeHoldSeconds
    let zoomStart = routeHoldEnd + NationalRouteMapRenderer.routeUndrawSeconds

    // Still fully drawn right as the pause ends.
    #expect(renderer.frameState(at: routeHoldEnd).routePointCount == 5)

    // Shrinking partway through the undraw.
    let midUndraw = renderer.frameState(
        at: routeHoldEnd + NationalRouteMapRenderer.routeUndrawSeconds / 2)
    #expect(midUndraw.routePointCount > 0)
    #expect(midUndraw.routePointCount < 5)

    // Gone by the time the zoom starts, and stays gone into the zoom.
    #expect(renderer.frameState(at: zoomStart).routePointCount == 0)
    #expect(renderer.frameState(at: zoomStart + 0.5).routePointCount == 0)
}

@Test func revealedRouteDrawsAThinOrangeSnake() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork()
    let routeStart =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds
        + NationalRouteMapRenderer.boxHoldSeconds
    let revealedTime = routeStart + NationalRouteMapRenderer.routeRevealSeconds

    let canvas = try SVGRasterizer.blankBitmap(width: 640, height: 360)
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    renderer.draw(at: revealedTime, artwork: artwork, into: context.cgContext)

    // The test route is tiny at national scale, so its whole length lands
    // near one pixel; search a small window around it for the route's
    // orange ink (top-left-origin, matching the grid projection directly).
    // The box's semi-transparent black stroke also passes through this
    // window and darkens the ink where it overlaps, so the check is for an
    // orange hue rather than an absolute brightness.
    let pixel = renderer.nationalBBox.pixelPosition(of: artwork.trackGridPoints[2])
    var orangeNearby = 0
    for y in max(0, Int(pixel.y) - 8)..<min(360, Int(pixel.y) + 8) {
        for x in max(0, Int(pixel.x) - 8)..<min(640, Int(pixel.x) + 8) {
            guard let colour = canvas.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            if colour.redComponent > colour.greenComponent * 1.5,
                colour.redComponent > colour.blueComponent * 1.5
            {
                orangeNearby += 1
            }
        }
    }
    #expect(orangeNearby > 0)
}

@Test func holdFrameShowsTheBoxAroundTheRouteArea() throws {
    let renderer = testRenderer()
    let artwork = try renderer.makeArtwork()

    let canvas = try SVGRasterizer.blankBitmap(width: 640, height: 360)
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    let holdTime =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds + 0.1
    renderer.draw(at: holdTime, artwork: artwork, into: context.cgContext)

    // Centroid of the box's semi-transparent black ink - grey once
    // composited over the white national map - should sit on the box's
    // centre. The frame rect is in Core Graphics bottom-left coordinates;
    // the bitmap scan is top-left, so flip y.
    let rect = renderer.frameRect(of: renderer.detailBBox, under: renderer.nationalBBox)
    var sumX = 0.0
    var sumY = 0.0
    var count = 0
    for y in 0..<360 {
        for x in 0..<640 {
            guard let colour = canvas.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.redComponent < 0.9,
                abs(colour.redComponent - colour.greenComponent) < 0.05,
                abs(colour.redComponent - colour.blueComponent) < 0.05
            else { continue }
            sumX += Double(x)
            sumY += Double(y)
            count += 1
        }
    }
    #expect(count > 0)
    #expect(abs(sumX / Double(count) - rect.midX) < 3)
    #expect(abs(sumY / Double(count) - (360 - rect.midY)) < 3)
}
