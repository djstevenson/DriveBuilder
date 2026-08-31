import AppKit
import ArgumentParser
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

private func smallConfig(labels: [RouteMapConfig.Label] = []) -> RouteMapConfig {
    var config = RouteMapConfig()
    config.width = 640
    config.height = 360
    config.framesPerSecond = 10
    config.introSeconds = 1
    config.animationSeconds = 2
    config.outroSeconds = 1
    config.labels = labels
    return config
}

@Test func popScaleEasesOutWithOvershoot() {
    #expect(RouteMapRenderer.popScale(0) == 0)
    #expect(RouteMapRenderer.popScale(1) == 1)
    #expect(abs(RouteMapRenderer.popScale(0.5) - 1.0876975) < 0.000_001)
    #expect(RouteMapRenderer.popScale(0.8) > 1)
}

@Test func configFileOverlaysDefaultsAndAllowsRelaxedJSON() throws {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "routemap-test-\(UUID().uuidString).json")
    // JSON5: comment and trailing commas, and only some keys given.
    try Data(
        """
        {
          // hand-edited config
          "output": { "width": 1920, "height": 1080, },
          "timing": { "animation": 30, },
          "labels": [
            { "offset": 60, "title": "A338", "subtitle": "Salisbury", "location": "left", },
          ],
        }
        """.utf8
    ).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }

    let config = try RouteMapConfig.load(path: path.path(percentEncoded: false))
    #expect(config.width == 1920)
    #expect(config.height == 1080)
    #expect(config.framesPerSecond == 30)  // default kept
    #expect(config.introSeconds == 2.5)  // default kept
    #expect(config.animationSeconds == 30)
    #expect(config.labels.count == 1)
    #expect(config.labels[0].location == "left")
    #expect(config.labels[0].distance == nil)

    let defaults = try RouteMapConfig.load(path: nil)
    #expect(defaults.width == 3840)
    #expect(defaults.labels.isEmpty)
}

@Test func configResolvesFromTheJourneySourceDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "routemap-journey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(
        """
        { "labels": [ { "offset": 0, "title": "A338", "subtitle": "Start" } ] }
        """.utf8
    ).write(to: directory.appending(path: "route_map.json"))

    let options = try RouteMapOptions.parse([])
    let journeyPath = directory.path(percentEncoded: false)

    // The conventional file beside the footage is picked up automatically.
    #expect(try options.loadConfig(journeyDirectory: journeyPath).labels.count == 1)
    // Without a journey directory (or without the file), defaults apply.
    #expect(try options.loadConfig(journeyDirectory: nil).labels.isEmpty)
    #expect(
        try options.loadConfig(journeyDirectory: "/nonexistent-\(UUID().uuidString)").labels.isEmpty)

    // An explicit path always wins over the convention, and must exist.
    let explicit = try RouteMapOptions.parse(
        ["--route-config", "/nonexistent-\(UUID().uuidString).json"])
    #expect(throws: (any Error).self) {
        try explicit.loadConfig(journeyDirectory: journeyPath)
    }
}

@Test func mapBBoxMatchesTheOutputAspect() {
    let renderer = RouteMapRenderer(
        records: testRecords(), tileRenderer: WhiteTileRenderer(), config: smallConfig())
    let bbox = renderer.mapBBox
    let aspect =
        (bbox.maxEasting - bbox.minEasting) / (bbox.maxNorthing - bbox.minNorthing)
    #expect(abs(aspect - 640.0 / 360.0) < 0.001)
    #expect(bbox.width == 640)
    #expect(bbox.height == 360)
}

@Test func framePlanCoversIntroAnimationAndOutro() {
    let records = testRecords(count: 100)
    let renderer = RouteMapRenderer(
        records: records, tileRenderer: WhiteTileRenderer(), config: smallConfig())

    let plan = renderer.framePlan
    // 1s intro + 2s animation + 1s outro at 10 fps.
    #expect(plan.count == 40)
    #expect(plan[0] == RouteMapRenderer.FrameSpec(pointCount: 0, videoTime: nil))
    #expect(plan[9].videoTime == nil)
    // First animation frame shows at least the minimum two points.
    #expect(plan[10].pointCount == max(2, Int(100.0 / 20.0 + 0.5)))
    #expect(plan[10].videoTime == 0.1)
    // The animation ends on the full track, and the outro holds it there.
    #expect(plan[29].pointCount == 100)
    #expect(plan[39] == RouteMapRenderer.FrameSpec(pointCount: 100, videoTime: 2))
}

@Test func labelsRevealInCompressedTime() {
    // Records span 40 s; a label at 20 s sits halfway: revealed at half the
    // animation, placed at the middle track point.
    let label = RouteMapConfig.Label(
        offset: 20, title: "A338", subtitle: "Salisbury", location: nil, distance: nil)
    let renderer = RouteMapRenderer(
        records: testRecords(count: 5),
        tileRenderer: WhiteTileRenderer(),
        config: smallConfig(labels: [label]))

    let points = [
        CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0),
        CGPoint(x: 30, y: 0), CGPoint(x: 40, y: 0),
    ]
    let placed = renderer.placeLabels(on: points)
    #expect(placed.count == 1)
    #expect(abs(placed[0].revealTime - 1.0) < 0.001)
    #expect(placed[0].point == CGPoint(x: 20, y: 0))
}

@Test func finalFrameShowsTrackHeadAndBothLabels() throws {
    // Two labels, so the test catches per-frame text state leaking from one
    // label's Core Text drawing into the next (the text matrix is not part
    // of the saved graphics state).
    let labels = [
        RouteMapConfig.Label(
            offset: 10, title: "A338", subtitle: "Bournemouth", location: nil, distance: nil),
        RouteMapConfig.Label(
            offset: 20, title: "A345", subtitle: "Salisbury", location: "left", distance: nil),
    ]
    let renderer = RouteMapRenderer(
        records: testRecords(count: 5),
        tileRenderer: WhiteTileRenderer(),
        config: smallConfig(labels: labels))
    let artwork = try renderer.makeArtwork()

    let canvas = try SVGRasterizer.blankBitmap(width: 640, height: 360)
    let context = try #require(NSGraphicsContext(bitmapImageRep: canvas))
    renderer.draw(
        RouteMapRenderer.FrameSpec(pointCount: 5, videoTime: 2),
        artwork: artwork, into: context.cgContext)

    // Track and head-marker orange (#ff4d1a) near the last track point, and
    // title-yellow (#cccc00) ink near each label's anchor.
    let head = artwork.trackPoints[4]
    var orangeNearHead = 0
    var yellowNearAnchor = [0, 0]
    for y in 0..<360 {
        for x in 0..<640 {
            guard let colour = canvas.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            if colour.redComponent > 0.8, colour.greenComponent < 0.5,
                colour.blueComponent < 0.4,
                abs(Double(x) - head.x) < 30, abs(Double(y) - head.y) < 30
            {
                orangeNearHead += 1
            }
            if colour.redComponent > 0.6, colour.greenComponent > 0.6,
                colour.blueComponent < 0.3
            {
                for (index, placed) in artwork.labels.enumerated()
                where abs(Double(x) - placed.point.x) < 450
                    && abs(Double(y) - placed.point.y) < 120
                {
                    yellowNearAnchor[index] += 1
                }
            }
        }
    }
    #expect(orangeNearHead > 300)
    #expect(yellowNearAnchor[0] > 50)
    #expect(yellowNearAnchor[1] > 50)
}
