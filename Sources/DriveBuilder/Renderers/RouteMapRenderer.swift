import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Output size, phase timings, and labels for the route map, read from an
/// optional JSON config file since they change from one video to the next.
///
/// Any section or key can be omitted to fall back to the defaults; labels
/// default to none. Parsed as JSON5 (trailing commas etc. allowed), since
/// this is a hand-edited file. The shape:
///
///     {
///       "output": { "width": 3840, "height": 2160, "fps": 30 },
///       "timing": { "intro": 5, "animation": 20, "outro": 5 },
///       "labels": [
///         {
///           "offset": 0, "title": "...", "subtitle": "...",
///           "location": "right", "distance": 75
///         }
///       ]
///     }
struct RouteMapConfig: Sendable {
    var width = 3840
    var height = 2160
    var framesPerSecond: Int32 = 30

    // Halved from 5.0: on top of the national establishing shot's own
    // outroSeconds hold, the two static holds back to back made for too
    // long a pause before the track starts snaking out.
    var introSeconds = 2.5
    var animationSeconds = 20.0
    var outroSeconds = 5.0

    var labels: [Label] = []

    /// A road-sign placard revealed as the track reaches its `offset`
    /// (seconds from the start of the telemetry) and left up thereafter.
    /// `location`/`distance` position it relative to that point.
    struct Label: Decodable, Sendable {
        var offset: Double
        var title: String
        var subtitle: String
        var location: String?
        var distance: Double?
    }

    /// Mirrors the file with everything optional, so a partial file
    /// overlays the defaults per key.
    private struct File: Decodable {
        struct Output: Decodable {
            var width: Int?
            var height: Int?
            var fps: Int32?
        }
        struct Timing: Decodable {
            var intro: Double?
            var animation: Double?
            var outro: Double?
        }
        var output: Output?
        var timing: Timing?
        var labels: [Label]?
    }

    static func load(path: String?) throws -> RouteMapConfig {
        var config = RouteMapConfig()
        guard let path else { return config }

        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let file = try decoder.decode(File.self, from: Data(contentsOf: URL(filePath: path)))

        config.width = file.output?.width ?? config.width
        config.height = file.output?.height ?? config.height
        config.framesPerSecond = file.output?.fps ?? config.framesPerSecond
        config.introSeconds = file.timing?.intro ?? config.introSeconds
        config.animationSeconds = file.timing?.animation ?? config.animationSeconds
        config.outroSeconds = file.timing?.outro ?? config.outroSeconds
        config.labels = file.labels ?? []
        return config
    }
}

/// Builds the route map: an overview of the whole journey shown at the start
/// of the video. `writeMovie` opens with `NationalRouteMapRenderer`'s
/// national establishing shot - Great Britain zooming smoothly into the
/// route's area - directly followed by this renderer's own static map, the
/// route "snaking" out faster than real time, then held static on the
/// completed track, with road-sign-style labels popping in as the track
/// reaches them. Both phases render into one continuous movie sharing the
/// same base map image, so there's no jump cut where they meet.
///
/// Full-screen output (4K by default) rather than a 420px dial.
struct RouteMapRenderer {
    static let dialName = "RouteMap"

    /// Extra margin added around the route's bounding box, as a fraction of
    /// the box's width/height, before matching the output's aspect ratio.
    static let bboxPadding = 0.10

    /// map.xml's road widths/shields/text were designed for a 1920px-wide
    /// render; scale them to match the actual output width so they don't
    /// look undersized at 4K.
    static let mapXMLDesignWidth = 1920.0

    static let trackColour = CGColor(srgbRed: 0xff / 255, green: 0x4d / 255, blue: 0x1a / 255, alpha: 1)
    static let trackLineWidth = 10.8
    static let trackCasingColour = CGColor(srgbRed: 0x33 / 255, green: 0x0d / 255, blue: 0, alpha: 1)
    static let trackCasingWidth = 16.0

    /// The leading-edge marker is a plain circle rather than a directional
    /// shape: heading swings rapidly at low speed and made a directional
    /// marker wave about distractingly.
    static let headMarkerRadius = 24.0
    static let headMarkerBorderWidth = 6.0

    /// Label styling matches the trunk-road shield styling used on the map.
    static let labelBoxColour = CGColor(srgbRed: 0x35 / 255, green: 0x6b / 255, blue: 0x4b / 255, alpha: 1)
    static let labelBorderColour = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let labelTitleColour = CGColor(srgbRed: 0xcc / 255, green: 0xcc / 255, blue: 0, alpha: 1)
    static let labelTextColour = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let labelBorderWidth = 4.0
    static let labelBoxRadius = 14.0
    static let labelBoxPadding = 24.0
    static let labelTopGap = 14.0
    static let labelTitleSize = 56.0
    static let labelSubtitleSize = 38.0
    static let labelLineGap = 24.0

    /// Gap between the point on the track and the near edge of the label.
    static let labelPointGap = 75.0

    static let labelAnchorRadius = 25.0
    static let labelArrowBaseWidth = 24.0

    /// How long, in video seconds, a label takes to pop in once revealed.
    static let labelPopSeconds = 0.35

    let records: [TelemetryRecord]
    let tileRenderer: any MapTileRenderer
    var config = RouteMapConfig()

    /// "easeOutBack": overshoots past 1 before settling, for a bit of a
    /// bounce on the pop. https://easings.net/#easeOutBack
    static func popScale(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let c1 = 1.70158
        let c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    /// Total telemetry duration, mapping a label's offset onto both a point
    /// on the track and a moment in the animation's compressed timescale.
    var totalSeconds: Double {
        guard let first = records.first, let last = records.last, records.count >= 2 else {
            return 0
        }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    /// The route's bounding box: padded in metres so the margin is
    /// physically uniform, then grown in whichever dimension is
    /// proportionally too small to match the output's aspect ratio,
    /// keeping the box centred.
    var mapBBox: MapBBox {
        var minEasting = Double.infinity
        var maxEasting = -Double.infinity
        var minNorthing = Double.infinity
        var maxNorthing = -Double.infinity
        for record in records {
            let grid = OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude)
            minEasting = min(minEasting, grid.easting)
            maxEasting = max(maxEasting, grid.easting)
            minNorthing = min(minNorthing, grid.northing)
            maxNorthing = max(maxNorthing, grid.northing)
        }

        // The 1 m floors keep a degenerate route renderable.
        var widthMetres = max((maxEasting - minEasting) * (1 + 2 * Self.bboxPadding), 1)
        var heightMetres = max((maxNorthing - minNorthing) * (1 + 2 * Self.bboxPadding), 1)

        let targetAspect = Double(config.width) / Double(config.height)
        if widthMetres / heightMetres > targetAspect {
            heightMetres = widthMetres / targetAspect
        } else {
            widthMetres = heightMetres * targetAspect
        }

        let centreEasting = (minEasting + maxEasting) / 2
        let centreNorthing = (minNorthing + maxNorthing) / 2

        return MapBBox(
            minEasting: centreEasting - widthMetres / 2,
            minNorthing: centreNorthing - heightMetres / 2,
            maxEasting: centreEasting + widthMetres / 2,
            maxNorthing: centreNorthing + heightMetres / 2,
            width: config.width,
            height: config.height)
    }

    /// A label placed on the map: video seconds into the animation phase at
    /// which it appears, and its pixel position from the track point nearest
    /// its telemetry offset.
    struct PlacedLabel {
        let label: RouteMapConfig.Label
        let revealTime: Double
        let point: CGPoint
    }

    /// Everything precomputed once and shared by every frame.
    struct Artwork {
        let map: CGImage
        let bbox: MapBBox

        /// Pixel position of every telemetry record within the base map, in
        /// order, so each frame just strokes a prefix of this list.
        let trackPoints: [CGPoint]

        let labels: [PlacedLabel]
    }

    func makeArtwork() throws -> Artwork {
        let bbox = mapBBox
        let trackPoints = records.map { record in
            bbox.pixelPosition(
                of: OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude))
        }
        return Artwork(
            map: try tileRenderer.renderMap(bbox),
            bbox: bbox,
            trackPoints: trackPoints,
            labels: placeLabels(on: trackPoints))
    }

    /// Records are evenly spaced in time, so a label's offset as a fraction
    /// of the total duration picks both its track point and its reveal
    /// moment in the compressed animation timescale.
    func placeLabels(on trackPoints: [CGPoint]) -> [PlacedLabel] {
        guard !config.labels.isEmpty, !trackPoints.isEmpty else { return [] }
        let totalSeconds = totalSeconds

        return config.labels
            .map { label in
                let fraction = totalSeconds > 0 ? label.offset / totalSeconds : 0
                let index = max(
                    0,
                    min(
                        trackPoints.count - 1,
                        Int(fraction * Double(trackPoints.count - 1) + 0.5)))
                return PlacedLabel(
                    label: label,
                    revealTime: fraction * config.animationSeconds,
                    point: trackPoints[index])
            }
            .sorted { $0.revealTime < $1.revealTime }
    }

    // MARK: - Frame plan

    /// What one output frame shows: how much of the track, and (for the
    /// animation and outro phases) the video time that gates the labels.
    struct FrameSpec: Equatable {
        let pointCount: Int
        let videoTime: Double?
    }

    /// The whole video, frame by frame: a static intro, the animated track
    /// growing from start to finish (the whole trip compressed into the
    /// animation phase), and a static outro with the full track and all
    /// labels.
    var framePlan: [FrameSpec] {
        let fps = Double(config.framesPerSecond)
        let introFrames = Int((config.introSeconds * fps).rounded())
        let animationFrames = Int((config.animationSeconds * fps).rounded())
        let outroFrames = Int((config.outroSeconds * fps).rounded())
        let pointCount = records.count

        var plan: [FrameSpec] = []
        plan.reserveCapacity(introFrames + animationFrames + outroFrames)

        for _ in 0..<introFrames {
            plan.append(FrameSpec(pointCount: 0, videoTime: nil))
        }
        if animationFrames > 0 {
            for frame in 1...animationFrames {
                let fraction = Double(frame) / Double(animationFrames)
                plan.append(
                    FrameSpec(
                        pointCount: max(
                            2, min(pointCount, Int(Double(pointCount) * fraction + 0.5))),
                        videoTime: Double(frame) / fps))
            }
        }
        for _ in 0..<outroFrames {
            plan.append(FrameSpec(pointCount: pointCount, videoTime: config.animationSeconds))
        }
        return plan
    }

    // MARK: - Drawing

    /// Draws one frame: the static map, the track prefix with its head
    /// marker, and any labels revealed by `videoTime`.
    func draw(_ spec: FrameSpec, artwork: Artwork, into context: CGContext) {
        LayerCompositor.draw(
            [.init(artwork.map)], into: context, width: config.width, height: config.height)

        // Everything else follows the Perl's top-left-origin geometry, so
        // flip once and draw in that space; text un-flips via textMatrix.
        context.saveGState()
        context.translateBy(x: 0, y: Double(config.height))
        context.scaleBy(x: 1, y: -1)

        if spec.pointCount >= 2 {
            Self.drawTrack(artwork.trackPoints[0..<spec.pointCount], into: context)
        }
        if let videoTime = spec.videoTime {
            for placed in artwork.labels where videoTime >= placed.revealTime {
                drawLabel(placed, videoTime: videoTime, into: context)
            }
        }

        context.restoreGState()
    }

    /// Strokes the travelled track and its leading-edge marker in top-left-
    /// origin coordinates. Shared with the progress map, which draws the
    /// travelled route in exactly this style but with a smaller marker.
    static func drawTrack(
        _ points: ArraySlice<CGPoint>,
        markerRadius: Double = headMarkerRadius,
        markerBorderWidth: Double = headMarkerBorderWidth,
        lineWidth: Double = trackLineWidth,
        casingWidth: Double = trackCasingWidth,
        into context: CGContext
    ) {
        guard let head = points.last else { return }

        if points.count >= 2 {
            let path = CGMutablePath()
            path.addLines(between: Array(points))

            context.setLineJoin(.round)
            context.setLineCap(.round)

            // Dark casing first, so the track stays visible over any background
            // colour, then the bright track colour on top.
            context.addPath(path)
            context.setStrokeColor(trackCasingColour)
            context.setLineWidth(casingWidth)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(trackColour)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }

        // Circular marker at the leading edge of the track.
        let headRect = CGRect(
            x: head.x - markerRadius,
            y: head.y - markerRadius,
            width: markerRadius * 2,
            height: markerRadius * 2)
        context.setFillColor(trackColour)
        context.fillEllipse(in: headRect)
        context.setStrokeColor(trackCasingColour)
        context.setLineWidth(markerBorderWidth)
        context.strokeEllipse(in: headRect)
    }

    /// A small road-sign-green placard offset to the side of the label's
    /// location: an anchor dot marks the exact point, the sign itself
    /// (sized to fit its text) sits to its "location" side, and the whole
    /// thing pops in from the anchor with a bit of overshoot.
    private func drawLabel(_ placed: PlacedLabel, videoTime: Double, into context: CGContext) {
        let point = placed.point
        let popFraction = min(1, max(0, (videoTime - placed.revealTime) / Self.labelPopSeconds))
        let scale = Self.popScale(popFraction)
        guard scale > 0 else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -point.x, y: -point.y)

        let titleFont = NSFont.transport(size: Self.labelTitleSize)
        let subtitleFont = NSFont.transport(size: Self.labelSubtitleSize)
        let title = Self.textLine(placed.label.title, font: titleFont)
        let subtitle = Self.textLine(placed.label.subtitle, font: subtitleFont)
        Self.resetTextMatrix(in: context)
        let titleBounds = CTLineGetImageBounds(title, context)
        let subtitleBounds = CTLineGetImageBounds(subtitle, context)

        let boxWidth = max(titleBounds.width, subtitleBounds.width) + 2 * Self.labelBoxPadding
        let boxHeight =
            Self.labelTopGap + Self.labelTitleSize + Self.labelLineGap
            + Self.labelSubtitleSize + Self.labelBoxPadding

        let distance = placed.label.distance ?? Self.labelPointGap

        // The edge of the box nearest the point (where the connector
        // attaches) is its left edge when the sign sits to the right of the
        // point, or its right edge when it sits to the left.
        let boxX: Double
        let arrowBaseX: Double
        if placed.label.location == "left" {
            boxX = point.x - distance - boxWidth
            arrowBaseX = boxX + boxWidth
        } else {
            boxX = point.x + distance
            arrowBaseX = boxX
        }
        let boxY = point.y - boxHeight / 2

        // Tapered connector from the sign to the exact point - drawn first
        // so the circle and box (drawn next) tuck over its ends.
        let connector = CGMutablePath()
        connector.move(to: CGPoint(x: arrowBaseX, y: point.y - Self.labelArrowBaseWidth / 2))
        connector.addLine(to: CGPoint(x: arrowBaseX, y: point.y + Self.labelArrowBaseWidth / 2))
        connector.addLine(to: point)
        connector.closeSubpath()
        fillAndStroke(
            connector, strokeWidth: Self.labelBorderWidth, into: context)

        let anchor = CGPath(
            ellipseIn: CGRect(
                x: point.x - Self.labelAnchorRadius,
                y: point.y - Self.labelAnchorRadius,
                width: Self.labelAnchorRadius * 2,
                height: Self.labelAnchorRadius * 2),
            transform: nil)
        fillAndStroke(anchor, strokeWidth: 3, into: context)

        let box = CGPath(
            roundedRect: CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight),
            cornerWidth: Self.labelBoxRadius,
            cornerHeight: Self.labelBoxRadius,
            transform: nil)
        fillAndStroke(box, strokeWidth: Self.labelBorderWidth, into: context)

        // Transport's glyphs sit about a font-size's eighth higher above
        // the baseline than the sans-serif these offsets were tuned for,
        // so nudge each baseline down by that much to keep the ink in
        // place.
        let boxCentreX = boxX + boxWidth / 2
        Self.drawText(
            title, bounds: titleBounds, colour: Self.labelTitleColour,
            centredOn: boxCentreX,
            baselineY: boxY + Self.labelTopGap + Self.labelTitleSize + Self.labelTitleSize / 8,
            into: context)
        Self.drawText(
            subtitle, bounds: subtitleBounds, colour: Self.labelTextColour,
            centredOn: boxCentreX,
            baselineY: boxY + Self.labelTopGap + Self.labelTitleSize
                + Self.labelLineGap + Self.labelSubtitleSize + Self.labelSubtitleSize / 8,
            into: context)

        context.restoreGState()
    }

    private func fillAndStroke(_ path: CGPath, strokeWidth: Double, into context: CGContext) {
        context.addPath(path)
        context.setFillColor(Self.labelBoxColour)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(Self.labelBorderColour)
        context.setLineWidth(strokeWidth)
        context.strokePath()
    }

    private static func textLine(_ string: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
    }

    /// Un-flips text drawn inside the frame's top-left-origin transform.
    ///
    /// Must be reapplied before every Core Text measure or draw: the text
    /// matrix is not part of the graphics state, and `CTLineDraw` leaves it
    /// modified, which otherwise loses the flip for every label after the
    /// frame's first.
    private static func resetTextMatrix(in context: CGContext) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    /// Draws a measured line with its ink centred on `centredOn`, matching
    /// the Perl's extents-based centring.
    private static func drawText(
        _ line: CTLine, bounds: CGRect, colour: CGColor,
        centredOn centreX: Double, baselineY: Double, into context: CGContext
    ) {
        resetTextMatrix(in: context)
        context.setFillColor(colour)
        context.textPosition = CGPoint(
            x: centreX - bounds.width / 2 - bounds.minX, y: baselineY)
        CTLineDraw(line, context)
    }

    // MARK: - Movie

    /// Writes the merged clip: `NationalRouteMapRenderer`'s national
    /// establishing shot, immediately followed by this renderer's own
    /// frames, as one continuous movie.
    ///
    /// The route map's own base image is rendered once, up front, and
    /// handed to the national renderer as its zoom target and its final
    /// image - the two phases were previously separate movies, each
    /// rendering this journey's detail map independently, and the external
    /// map renderer could place road/place labels slightly differently
    /// between those two calls; cutting between the resulting files then
    /// showed a jump as the labels snapped to their other rendering.
    /// Sharing one image removes that: the last frame of the zoom and the
    /// first frame of the reveal are pixel-identical.
    func writeMovie(
        nationalTileRenderer: any MapTileRenderer,
        to url: URL,
        frameLimit: Int? = nil,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws {
        let artwork = try makeArtwork()

        let national = NationalRouteMapRenderer(
            records: records, nationalTileRenderer: nationalTileRenderer,
            detail: artwork.map, detailBBox: artwork.bbox, config: config)
        let nationalArtwork = try national.makeArtwork()

        var nationalPlan = national.framePlan
        var routePlan = framePlan
        if let frameLimit {
            nationalPlan = Array(nationalPlan.prefix(frameLimit))
            routePlan = Array(routePlan.prefix(max(0, frameLimit - nationalPlan.count)))
        }
        let frameCount = nationalPlan.count + routePlan.count

        print(
            "\(Self.dialName): \(records.count) telemetry records, rendering \(frameCount) "
                + "frames at \(config.width)x\(config.height) \(config.framesPerSecond) fps.")
        print(
            String(
                format: "  %@ establishing shot (%.0fs), then %.0fs intro, %.0fs animation, "
                    + "%.0fs outro; %d labels; %d-way compositing",
                NationalRouteMapRenderer.dialName, NationalRouteMapRenderer.totalSeconds,
                config.introSeconds, config.animationSeconds, config.outroSeconds,
                config.labels.count, concurrency))

        var writer = AlphaMovieWriter(
            url: url, width: config.width, height: config.height,
            framesPerSecond: config.framesPerSecond)
        writer.concurrency = concurrency

        let started = ContinuousClock.now
        try await writer.write(
            frameCount: frameCount,
            progress: { done in
                guard done % 100 == 0 || done == frameCount else { return }
                FileHandle.standardError.write(Data("  \(done)/\(frameCount) frames\n".utf8))
            },
            drawFrame: { index, context in
                if index < nationalPlan.count {
                    national.draw(at: nationalPlan[index], artwork: nationalArtwork, into: context)
                } else {
                    draw(routePlan[index - nationalPlan.count], artwork: artwork, into: context)
                }
            })

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs (%.3f ms/frame) to %@",
                Double(frameCount) / Double(config.framesPerSecond),
                config.width, config.height,
                seconds, seconds * 1000 / Double(max(frameCount, 1)),
                url.path(percentEncoded: false)))
    }
}
