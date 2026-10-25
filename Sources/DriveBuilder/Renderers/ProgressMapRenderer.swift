import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// Builds the overview progress map for a journey: a static map covering the
/// whole route, with the route travelled so far drawn over it in the route
/// map's style — an orange line ending in an orange circle at the current
/// position.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
enum ProgressMapError: Error, CustomStringConvertible {
    case trackLayerFailed

    var description: String { "Could not pre-render the progress map's track" }
}

struct ProgressMapRenderer: DialRenderer {
    static let dialName = "ProgressMap"

    /// Extra margin added around the route's bounding box, as a fraction of
    /// the box's width/height, applied before squaring.
    static let bboxPadding = 0.10

    /// The current-position marker is half the route map's size, with a
    /// black arrow inside it showing the heading. Sized for the design
    /// frame; scaled by `scale` when drawn.
    static let markerRadius = RouteMapRenderer.headMarkerRadius / 2
    static let markerBorderWidth = RouteMapRenderer.headMarkerBorderWidth / 2

    /// The frame size the map's proportions were designed at; rendering at
    /// another size scales the whole picture rather than changing the view.
    static let designPixelSize = 420.0

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// How much the marker, track, and arrow grow relative to the design size.
    var scale: Double { Double(pixelSize) / Self.designPixelSize }

    let tileRenderer: any MapTileRenderer

    /// The whole route's bounding box: padded in metres (not degrees) so the
    /// margin is physically uniform, then squared by expanding whichever side
    /// is shorter, keeping it centred.
    var routeBBox: MapBBox {
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

        let paddedWidth = (maxEasting - minEasting) * (1 + 2 * Self.bboxPadding)
        let paddedHeight = (maxNorthing - minNorthing) * (1 + 2 * Self.bboxPadding)
        // The 1 m floor keeps a degenerate route (a single point) renderable.
        let side = max(paddedWidth, paddedHeight, 1)
        let half = side / 2

        let centreEasting = (minEasting + maxEasting) / 2
        let centreNorthing = (minNorthing + maxNorthing) / 2

        return MapBBox(
            minEasting: centreEasting - half,
            minNorthing: centreNorthing - half,
            maxEasting: centreEasting + half,
            maxNorthing: centreNorthing + half,
            width: pixelSize,
            height: pixelSize)
    }

    /// Track points between cached track layers (see `Artwork.trackLayers`):
    /// 20 seconds of 30 fps records, so a frame strokes at most this many
    /// points live.
    static let trackLayerInterval = 600

    /// The travelled track up to one point, pre-stroked: the casing and the
    /// bright line as separate full-frame layers, so a frame can slot the
    /// rest of the track's casing in beneath all of the line, just as
    /// stroking the whole track at once would.
    struct TrackLayers {
        let casing: CGImage
        let line: CGImage
    }

    /// Artwork rasterized once and reused for every frame: the route-covering
    /// base map, the pixel position of every telemetry record in order, and
    /// the track pre-stroked up to every `trackLayerInterval`th point.
    ///
    /// Stroking the whole travelled prefix every frame made each frame's
    /// cost grow with the distance covered, and the whole render quadratic
    /// in the journey's length; with the layers a frame strokes only the
    /// tail since the last one. `trackLayers[k]` covers points
    /// `0...(k + 1) * trackLayerInterval`.
    struct Artwork {
        let map: CGImage
        let bbox: MapBBox
        let trackPoints: [CGPoint]
        let trackLayers: [TrackLayers]
    }

    func makeArtwork() throws -> Artwork {
        let bbox = routeBBox
        let trackPoints = records.map { record in
            bbox.pixelPosition(
                of: OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude))
        }
        return Artwork(
            map: try tileRenderer.renderMap(bbox),
            bbox: bbox,
            trackPoints: trackPoints,
            trackLayers: try makeTrackLayers(trackPoints))
    }

    /// Strokes every cached track layer, in parallel: each is independent,
    /// and a long journey has a few hundred.
    private func makeTrackLayers(_ trackPoints: [CGPoint]) throws -> [TrackLayers] {
        let count = max(0, (trackPoints.count - 1) / Self.trackLayerInterval)
        let (pixelSize, scale) = (pixelSize, scale)
        let layers = Mutex([TrackLayers?](repeating: nil, count: count))
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let points = trackPoints[0...(index + 1) * Self.trackLayerInterval]
            guard
                let casing = Self.trackLayer(
                    points, colour: RouteMapRenderer.trackCasingColour,
                    width: RouteMapRenderer.trackCasingWidth * scale, pixelSize: pixelSize),
                let line = Self.trackLayer(
                    points, colour: RouteMapRenderer.trackColour,
                    width: RouteMapRenderer.trackLineWidth * scale, pixelSize: pixelSize)
            else { return }
            layers.withLock { $0[index] = TrackLayers(casing: casing, line: line) }
        }
        let built = layers.withLock { $0.compactMap { $0 } }
        guard built.count == count else { throw ProgressMapError.trackLayerFailed }
        return built
    }

    /// One pass of the track, alone on a transparent frame-sized image.
    private static func trackLayer(
        _ points: ArraySlice<CGPoint>, colour: CGColor, width: Double, pixelSize: Int
    ) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        flipToTrackSpace(context, pixelSize: pixelSize)
        RouteMapRenderer.strokeTrack(points, colour: colour, width: width, into: context)
        return context.makeImage()
    }

    /// Track points follow the top-left-origin frame geometry, so flip
    /// once and draw in that space, as the route map does.
    private static func flipToTrackSpace(_ context: CGContext, pixelSize: Int) {
        context.translateBy(x: 0, y: Double(pixelSize))
        context.scaleBy(x: 1, y: -1)
    }

    /// Draws one frame into `context`: the static map, then the route
    /// travelled so far with the circular marker at the current position,
    /// exactly as the route map draws its track.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        LayerCompositor.draw(
            [.init(artwork.map)], into: context, width: pixelSize, height: pixelSize)

        let travelledCount = travelledCount(at: record)
        guard travelledCount > 0 else { return }

        // The latest cached layer behind the head, if any, and the tail of
        // points since it (sharing its last point, so the strokes join).
        // Artwork without layers just strokes the whole track live.
        let layerIndex = min(
            (travelledCount - 1) / Self.trackLayerInterval - 1, artwork.trackLayers.count - 1)
        let layer = layerIndex >= 0 ? artwork.trackLayers[layerIndex] : nil
        let tailStart = (layerIndex + 1) * Self.trackLayerInterval
        let tail = artwork.trackPoints[tailStart..<travelledCount]
        let frame = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

        // Casing beneath line throughout, as `RouteMapRenderer.drawTrack`
        // strokes it in one go.
        if let layer { context.draw(layer.casing, in: frame) }
        inTrackSpace(context) {
            RouteMapRenderer.strokeTrack(
                tail, colour: RouteMapRenderer.trackCasingColour,
                width: RouteMapRenderer.trackCasingWidth * scale, into: $0)
        }
        if let layer { context.draw(layer.line, in: frame) }
        inTrackSpace(context) {
            RouteMapRenderer.strokeTrack(
                tail, colour: RouteMapRenderer.trackColour,
                width: RouteMapRenderer.trackLineWidth * scale, into: $0)
            let head = artwork.trackPoints[travelledCount - 1]
            RouteMapRenderer.drawHeadMarker(
                at: head, radius: Self.markerRadius * scale,
                borderWidth: Self.markerBorderWidth * scale, into: $0)
            drawHeadingArrow(at: head, headingDegrees: record.heading, into: $0)
        }
    }

    private func inTrackSpace(_ context: CGContext, _ body: (CGContext) -> Void) {
        context.saveGState()
        Self.flipToTrackSpace(context, pixelSize: pixelSize)
        body(context)
        context.restoreGState()
    }

    /// A black arrow inside the marker circle, pointing along the heading.
    private func drawHeadingArrow(
        at point: CGPoint, headingDegrees: Double, into context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        // In the flipped, top-left-origin track space a positive rotation
        // appears clockwise on screen, matching the heading's sense; at 0°
        // the arrow points up (north).
        context.rotate(by: headingDegrees * .pi / 180)

        // Tip, starboard corner, tail notch, port corner - proportioned to
        // sit inside the marker's border.
        let r = Self.markerRadius * scale
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 0, y: -0.65 * r))
        arrow.addLine(to: CGPoint(x: 0.5 * r, y: 0.55 * r))
        arrow.addLine(to: CGPoint(x: 0, y: 0.25 * r))
        arrow.addLine(to: CGPoint(x: -0.5 * r, y: 0.55 * r))
        arrow.closeSubpath()

        context.addPath(arrow)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    /// How many records the journey has covered by `record`'s moment, found
    /// by timestamp since frames are drawn concurrently and the record's
    /// index is not handed to `draw`.
    private func travelledCount(at record: TelemetryRecord) -> Int {
        var low = 0
        var high = records.count
        while low < high {
            let mid = (low + high) / 2
            if records[mid].timestamp <= record.timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let bbox = artwork.bbox
        return [
            String(
                format: "  route area %.1f km square, %d-way compositing",
                (bbox.maxEasting - bbox.minEasting) / 1000, concurrency)
        ]
    }
}
