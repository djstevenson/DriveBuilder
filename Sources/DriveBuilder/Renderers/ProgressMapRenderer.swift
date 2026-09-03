import AppKit
import CoreGraphics
import Foundation

/// Builds the overview progress map for a journey: a static map covering the
/// whole route, with the route travelled so far drawn over it in the route
/// map's style — an orange line ending in an orange circle at the current
/// position.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
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

    /// Artwork rasterized once and reused for every frame: the route-covering
    /// base map, and the pixel position of every telemetry record in order,
    /// so each frame just strokes a prefix of the list.
    struct Artwork {
        let map: CGImage
        let bbox: MapBBox
        let trackPoints: [CGPoint]
    }

    func makeArtwork() throws -> Artwork {
        let bbox = routeBBox
        return Artwork(
            map: try tileRenderer.renderMap(bbox),
            bbox: bbox,
            trackPoints: records.map { record in
                bbox.pixelPosition(
                    of: OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude))
            })
    }

    /// Draws one frame into `context`: the static map, then the route
    /// travelled so far with the circular marker at the current position,
    /// exactly as the route map draws its track.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        LayerCompositor.draw(
            [.init(artwork.map)], into: context, width: pixelSize, height: pixelSize)

        // Track points follow the top-left-origin frame geometry, so flip
        // once and draw in that space, as the route map does.
        context.saveGState()
        context.translateBy(x: 0, y: Double(pixelSize))
        context.scaleBy(x: 1, y: -1)
        let travelled = artwork.trackPoints[0..<travelledCount(at: record)]
        RouteMapRenderer.drawTrack(
            travelled,
            markerRadius: Self.markerRadius * scale,
            markerBorderWidth: Self.markerBorderWidth * scale,
            lineWidth: RouteMapRenderer.trackLineWidth * scale,
            casingWidth: RouteMapRenderer.trackCasingWidth * scale,
            into: context)
        if let head = travelled.last {
            drawHeadingArrow(at: head, headingDegrees: record.heading, into: context)
        }
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
