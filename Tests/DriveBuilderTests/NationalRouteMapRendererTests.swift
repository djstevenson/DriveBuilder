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
        source: "test",
        odometer: 0)
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
private func testRenderer(records: [TelemetryRecord] = testRecords()) -> NationalRouteMapRenderer {
    let config = smallConfig()
    let detailBBox = RouteMapRenderer(
        records: records, tileRenderer: SolidTileRenderer(red: 1, green: 0, blue: 0),
        config: config
    ).mapBBox
    let detail = try! SolidTileRenderer(red: 1, green: 0, blue: 0).renderMap(detailBBox)

    return NationalRouteMapRenderer(
        records: records,
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

    // Intro: just the country; the box still off screen, nothing dimmed.
    let intro = renderer.frameState(at: 0)
    #expect(intro.viewport == national)
    #expect(intro.boxProgress == 0)
    #expect(intro.overlayAlpha == 0)
    #expect(intro.detailAlpha == 0)

    // Mid-sweep: the box is travelling in, its outline strengthening from a
    // third towards full while the dim rises.
    let midTime =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds / 2
    let mid = renderer.frameState(at: midTime)
    #expect(abs(mid.boxProgress - 0.5) < 0.000_001)  // smoothstep(0.5) == 0.5
    #expect(abs(mid.boxAlpha - 2.0 / 3) < 0.000_001)
    #expect(abs(mid.overlayAlpha - NationalRouteMapRenderer.overlayMaxAlpha / 2) < 0.000_001)

    // Hold after the sweep: box settled at full opacity over the dimmed
    // surroundings; camera still wide.
    let holdTime =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds + 0.1
    let hold = renderer.frameState(at: holdTime)
    #expect(hold.viewport == national)
    #expect(hold.boxProgress == 1)
    #expect(hold.boxAlpha == 1)
    #expect(abs(hold.overlayAlpha - NationalRouteMapRenderer.overlayMaxAlpha) < 0.000_001)
    #expect(hold.detailAlpha == 0)

    // End of the zoom and the outro: exactly the route map's area, fully
    // detailed, box and dim gone.
    let end = renderer.frameState(at: NationalRouteMapRenderer.totalSeconds)
    #expect(end.viewport == route)
    #expect(end.detailAlpha == 1)
    #expect(end.boxAlpha == 0)
    #expect(end.overlayAlpha == 0)
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
    // The box and the outside-the-area dim persist until the zoom is
    // under way.
    #expect(holdEnd.boxAlpha == 1)
    #expect(
        abs(holdEnd.overlayAlpha - NationalRouteMapRenderer.overlayMaxAlpha) < 0.000_001)
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

@Test func holdFrameDimsTheCountryOutsideTheRouteArea() throws {
    // A route spanning the best part of a degree, so its box has an
    // interior tens of pixels across at the test's 640x360 national scale;
    // the default test route's box is subpixel here.
    let start = Date(timeIntervalSince1970: 1_775_000_000)
    let wideRecords = (0..<5).map {
        record(
            latitude: 51.0 + Double($0) * 0.2,
            longitude: -1.5 + Double($0) * 0.3,
            timestamp: start.addingTimeInterval(Double($0) * 10))
    }
    let renderer = testRenderer(records: wideRecords)
    let artwork = try renderer.makeArtwork()

    let canvas = try SVGRasterizer.blankBitmap(width: 640, height: 360)
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    let holdTime =
        NationalRouteMapRenderer.introSeconds + NationalRouteMapRenderer.boxPopSeconds + 0.1
    renderer.draw(at: holdTime, artwork: artwork, into: context.cgContext)

    // Inside the route's area the white national map shows undimmed. The
    // frame rect is in Core Graphics bottom-left coordinates; the bitmap
    // scan is top-left, so flip y.
    let rect = renderer.frameRect(of: renderer.detailBBox, under: renderer.nationalBBox)
    let inside = try #require(
        canvas.colorAt(x: Int(rect.midX), y: 360 - Int(rect.midY))?.usingColorSpace(.deviceRGB))
    #expect(inside.redComponent > 0.98)
    #expect(inside.greenComponent > 0.98)

    // A corner well away from the box: dimmed to roughly 70% white.
    let outside = try #require(canvas.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
    #expect(abs(outside.redComponent - 0.7) < 0.03)
    #expect(abs(outside.redComponent - outside.greenComponent) < 0.01)
    #expect(abs(outside.redComponent - outside.blueComponent) < 0.01)

    // The settled outline: near-black ink within a few rows of the box's
    // top edge (the 5px stroke straddles the boundary).
    let edgeRow = 360 - Int(rect.maxY)
    let strokeInk = ((edgeRow - 4)...(edgeRow + 4)).contains { y in
        guard let c = canvas.colorAt(x: Int(rect.midX), y: y)?.usingColorSpace(.deviceRGB)
        else { return false }
        return c.redComponent < 0.2
    }
    #expect(strokeInk)
}
