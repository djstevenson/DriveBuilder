import CoreGraphics
import Foundation

/// Builds the national establishing shot that leads into the route map. A
/// map of Great Britain fills the frame, a box sweeps in from just outside
/// the frame's edges — its outline strengthening as it converges on the area
/// the route map covers, while the country outside it dims — and the camera
/// zooms into that area. The final frame is exactly the route map's own base
/// image, so `RouteMapRenderer` can play its own frames straight on from
/// these with no jump cut.
///
/// The country is rendered here, in a low-detail style (main roads and
/// motorways only); the route's own detailed base image is rendered by
/// `RouteMapRenderer` and passed in, so it's the very same image the route
/// map itself then reveals its track over - rendering it twice risked the
/// external map renderer placing labels slightly differently between the
/// two calls, which is what the jump cut this replaces was. Before the zoom
/// sets off, the detailed image cross-fades in over the national image
/// inside the box, in its correct map position, so the zoom magnifies
/// imagery that's already sharp.
struct NationalRouteMapRenderer {
    static let dialName = "NationalRouteMap"

    /// Great Britain in National Grid metres: Cornwall to Caithness. The box
    /// is grown to the output's aspect ratio, so the country fills the frame
    /// height with sea either side.
    static let gbMinEasting = 60_000.0
    static let gbMaxEasting = 660_000.0
    static let gbMinNorthing = 5_000.0
    static let gbMaxNorthing = 975_000.0

    /// Extra margin around the country, as a fraction of its height.
    static let gbPadding = 0.02

    // Phase timings, in video seconds. The zoom is the shot's point; the
    // holds either side give the edit somewhere to cut.
    static let introSeconds = 2.0
    static let boxPopSeconds = 0.8
    static let boxHoldSeconds = 1.2
    static let routeRevealSeconds = 1.5
    static let routeHoldSeconds = 1.0
    static let routeUndrawSeconds = 1.0 / 3
    /// Cross-fade from the low-detail national imagery to the route map's
    /// own high-detail image inside the box, before the zoom sets off, so
    /// the zoom magnifies imagery that's already sharp.
    static let detailSwapSeconds = 0.5
    static let zoomSeconds = 3.0
    // Halved from 1.0: combined with the route map's own introSeconds hold
    // right after it, the two static holds back to back made for too long
    // a pause before the track starts snaking out.
    static let outroSeconds = 0.5

    /// The box outline and the outside-the-box dim fade out over this window
    /// of the zoom, before the box's edges reach the frame border, so the
    /// final frames are clean for the cut.
    static let zoomFadeOutStart = 0.5
    static let zoomFadeOutEnd = 0.8

    /// Black rather than the track's orange, so the sweep-in box that
    /// previews the route's area doesn't read as the same colour as the
    /// route preview drawn over it moments later. Thin and fully opaque:
    /// a heavier translucent stroke read as a smudge over the map.
    static let boxColour = CGColor(gray: 0, alpha: 1)
    static let boxLineWidth = 5.0

    /// Peak opacity of the black dim over everything outside the route's
    /// area, reached as the box finishes its sweep.
    static let overlayMaxAlpha = 0.3

    /// The outline's opacity at the start of the sweep; it fades up to full
    /// as the box converges on the route's area. A third rather than zero so
    /// the thin, fast-moving line already reads during the sweep itself.
    static let boxMinAlpha = 1.0 / 3

    /// The route preview, drawn in the same "orange snake" style as the
    /// route map's own track, but thinner: at this zoomed-out scale the
    /// route's on-screen length is short, and the route map's dial-scale
    /// width would draw as a blob rather than a line.
    static let routeLineWidth = RouteMapRenderer.trackLineWidth / 2
    static let routeCasingWidth = RouteMapRenderer.trackCasingWidth / 2
    static let routeMarkerRadius = RouteMapRenderer.headMarkerRadius / 4
    static let routeMarkerBorderWidth = RouteMapRenderer.headMarkerBorderWidth / 4

    let records: [TelemetryRecord]

    /// Renders the country-wide base image (the low-detail stylesheet).
    let nationalTileRenderer: any MapTileRenderer

    /// The route map's own base image and the bbox it was rendered at -
    /// `RouteMapRenderer.makeArtwork()`'s `map`/`bbox` - reused rather than
    /// re-rendered, so the zoom's final frame is pixel-identical to what the
    /// route map then reveals its track over.
    let detail: CGImage
    let detailBBox: MapBBox

    /// The route map's config: its output size and frame rate are reused
    /// here so the two phases of the merged movie match.
    var config = RouteMapConfig()

    /// The whole country, grown to the output's aspect ratio about its centre.
    var nationalBBox: MapBBox {
        var widthMetres = (Self.gbMaxEasting - Self.gbMinEasting)
        var heightMetres = (Self.gbMaxNorthing - Self.gbMinNorthing) * (1 + 2 * Self.gbPadding)

        let targetAspect = Double(config.width) / Double(config.height)
        if widthMetres / heightMetres > targetAspect {
            heightMetres = widthMetres / targetAspect
        } else {
            widthMetres = heightMetres * targetAspect
        }

        let centreEasting = (Self.gbMinEasting + Self.gbMaxEasting) / 2
        let centreNorthing = (Self.gbMinNorthing + Self.gbMaxNorthing) / 2

        return MapBBox(
            minEasting: centreEasting - widthMetres / 2,
            minNorthing: centreNorthing - heightMetres / 2,
            maxEasting: centreEasting + widthMetres / 2,
            maxNorthing: centreNorthing + heightMetres / 2,
            width: config.width,
            height: config.height)
    }

    // MARK: - Frame plan

    static var totalSeconds: Double {
        introSeconds + boxPopSeconds + boxHoldSeconds + routeRevealSeconds + routeHoldSeconds
            + routeUndrawSeconds + detailSwapSeconds + zoomSeconds + outroSeconds
    }

    /// One video time per output frame.
    var framePlan: [Double] {
        let fps = Double(config.framesPerSecond)
        let frames = Int((Self.totalSeconds * fps).rounded())
        return (0..<frames).map { Double($0) / fps }
    }

    /// Everything a frame draws, derived from its video time. Split out
    /// from the drawing so the animation's geometry is testable.
    struct FrameState {
        /// The map area the frame shows.
        var viewport: MapBBox
        /// Sweep-in progress of the box: 0 is a frame-sized rectangle just
        /// outside the video's edges, 1 is settled on the route's area.
        var boxProgress: Double
        /// The box outline's opacity: a third as the sweep starts, rising to
        /// full as it settles on the route's area, then fading back out
        /// during the zoom.
        var boxAlpha: Double
        /// Black dim over everything outside the box: rising as the box
        /// sweeps in, easing back out during the zoom so the final frames
        /// are clean for the cut.
        var overlayAlpha: Double
        var detailAlpha: Double
        /// How much of the route preview to draw: growing in as it reveals,
        /// holding at full length, then shrinking back to nothing before
        /// the zoom starts, so it never appears alongside the zoomed-in
        /// image and doesn't have to fade awkwardly as the camera moves.
        var routePointCount: Int
    }

    /// Ease for the zoom: gentle start and stop. https://easings.net/#easeInOutSine
    static func smoothstep(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return t * t * (3 - 2 * t)
    }

    /// 0 before `from`, 1 after `to`, linear in between.
    private static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        min(1, max(0, (value - from) / (to - from)))
    }

    func frameState(at time: Double) -> FrameState {
        let popStart = Self.introSeconds
        let routeStart = popStart + Self.boxPopSeconds + Self.boxHoldSeconds
        let routeRevealEnd = routeStart + Self.routeRevealSeconds
        let routeHoldEnd = routeRevealEnd + Self.routeHoldSeconds
        let routeUndrawEnd = routeHoldEnd + Self.routeUndrawSeconds
        let detailSwapStart = routeUndrawEnd
        let zoomStart = detailSwapStart + Self.detailSwapSeconds

        let popT = min(1, max(0, (time - popStart) / Self.boxPopSeconds))
        let boxProgress = Self.smoothstep(popT)
        let zoomProgress = Self.smoothstep((time - zoomStart) / Self.zoomSeconds)

        // Grows in over the reveal window; once past the hold that follows,
        // the same ramp run in reverse shrinks it back to nothing.
        let routeFraction =
            time < routeHoldEnd
            ? Self.ramp(time, from: routeStart, to: routeRevealEnd)
            : 1 - Self.ramp(time, from: routeHoldEnd, to: routeUndrawEnd)
        let routePointCount =
            records.count >= 2 && routeFraction > 0
            ? max(2, min(records.count, Int(Double(records.count) * routeFraction + 0.5)))
            : 0

        return FrameState(
            viewport: Self.viewport(
                at: zoomProgress, from: nationalBBox, to: detailBBox),
            boxProgress: boxProgress,
            boxAlpha: (Self.boxMinAlpha + (1 - Self.boxMinAlpha) * boxProgress)
                * (1 - Self.ramp(
                    zoomProgress, from: Self.zoomFadeOutStart, to: Self.zoomFadeOutEnd)),
            overlayAlpha: Self.overlayMaxAlpha * boxProgress
                * (1 - Self.ramp(
                    zoomProgress, from: Self.zoomFadeOutStart, to: Self.zoomFadeOutEnd)),
            detailAlpha: Self.ramp(
                time, from: detailSwapStart, to: detailSwapStart + Self.detailSwapSeconds),
            routePointCount: routePointCount)
    }

    /// The map area shown at eased zoom progress `t`: geometric scaling
    /// about the zoom's fixed point, so the shot reads as one continuous
    /// camera move with the target area staying put on screen.
    ///
    /// The fixed point is the screen position that maps to itself throughout
    /// the move; scaling the start viewport about it by the full ratio gives
    /// the end viewport, and by `ratio^t` gives every frame between.
    static func viewport(at t: Double, from start: MapBBox, to end: MapBBox) -> MapBBox {
        if t <= 0 { return start }
        if t >= 1 { return end }

        let ratio = (end.maxEasting - end.minEasting) / (start.maxEasting - start.minEasting)
        let scale = pow(ratio, t)

        func axis(_ start0: Double, _ start1: Double, _ end0: Double, _ end1: Double)
            -> (Double, Double)
        {
            let startCentre = (start0 + start1) / 2
            let endCentre = (end0 + end1) / 2
            let fixed = (endCentre - startCentre * ratio) / (1 - ratio)
            let centre = fixed + (startCentre - fixed) * scale
            let halfSpan = (start1 - start0) / 2 * scale
            return (centre - halfSpan, centre + halfSpan)
        }

        let (minEasting, maxEasting) = axis(
            start.minEasting, start.maxEasting, end.minEasting, end.maxEasting)
        let (minNorthing, maxNorthing) = axis(
            start.minNorthing, start.maxNorthing, end.minNorthing, end.maxNorthing)
        return MapBBox(
            minEasting: minEasting, minNorthing: minNorthing,
            maxEasting: maxEasting, maxNorthing: maxNorthing,
            width: start.width, height: start.height)
    }

    // MARK: - Drawing

    /// Everything precomputed once and shared by every frame.
    struct Artwork {
        let national: CGImage
        let nationalBBox: MapBBox
        let detail: CGImage
        let detailBBox: MapBBox

        /// Every telemetry record's grid position, in order. Kept as grid
        /// points rather than pixels: the viewport zooms frame to frame, so
        /// each frame projects these afresh onto its own current viewport.
        let trackGridPoints: [OSGB.GridPoint]
    }

    func makeArtwork() throws -> Artwork {
        Artwork(
            national: try nationalTileRenderer.renderMap(nationalBBox),
            nationalBBox: nationalBBox,
            detail: detail,
            detailBBox: detailBBox,
            trackGridPoints: records.map {
                OSGB.gridPoint(latitude: $0.latitude, longitude: $0.longitude)
            })
    }

    /// Where a map bbox lands in the frame under `viewport`, in Core
    /// Graphics bottom-left-origin coordinates.
    func frameRect(of bbox: MapBBox, under viewport: MapBBox) -> CGRect {
        let pixelsPerMetre =
            Double(config.width) / (viewport.maxEasting - viewport.minEasting)
        let x = (bbox.minEasting - viewport.minEasting) * pixelsPerMetre
        let yTop = (viewport.maxNorthing - bbox.maxNorthing) * pixelsPerMetre
        let width = (bbox.maxEasting - bbox.minEasting) * pixelsPerMetre
        let height = (bbox.maxNorthing - bbox.minNorthing) * pixelsPerMetre
        return CGRect(x: x, y: Double(config.height) - yTop - height,
                      width: width, height: height)
    }

    func draw(at time: Double, artwork: Artwork, into context: CGContext) {
        let state = frameState(at: time)

        context.interpolationQuality = .high
        context.draw(
            artwork.national, in: frameRect(of: artwork.nationalBBox, under: state.viewport))

        if state.detailAlpha > 0 {
            context.saveGState()
            context.setAlpha(state.detailAlpha)
            context.draw(
                artwork.detail, in: frameRect(of: artwork.detailBBox, under: state.viewport))
            context.restoreGState()
        }

        let boxRect = sweepRect(
            at: state.boxProgress,
            to: frameRect(of: artwork.detailBBox, under: state.viewport))

        if state.overlayAlpha > 0 {
            drawOverlay(outside: boxRect, alpha: state.overlayAlpha, into: context)
        }

        if state.routePointCount >= 2 {
            drawRoute(
                state.routePointCount, artwork: artwork, viewport: state.viewport, into: context)
        }

        if state.boxProgress > 0 && state.boxAlpha > 0 {
            drawBox(boxRect, alpha: state.boxAlpha, into: context)
        }
    }

    /// The sweeping box: a rectangle far enough outside the video's edges
    /// that its stroke is entirely off screen at progress 0, converging on
    /// the route-area rect at 1.
    private func sweepRect(at progress: Double, to target: CGRect) -> CGRect {
        let outset = Self.boxLineWidth
        let start = CGRect(
            x: -outset, y: -outset,
            width: Double(config.width) + 2 * outset,
            height: Double(config.height) + 2 * outset)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return CGRect(
            x: lerp(start.minX, target.minX),
            y: lerp(start.minY, target.minY),
            width: lerp(start.width, target.width),
            height: lerp(start.height, target.height))
    }

    /// Fills everything outside `rect` with black at `alpha`, dimming the
    /// country around the route's area.
    private func drawOverlay(outside rect: CGRect, alpha: Double, into context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(Self.boxColour)
        context.addRect(
            CGRect(x: 0, y: 0, width: Double(config.width), height: Double(config.height)))
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// Draws the revealed prefix of the route preview, projected onto the
    /// current viewport. Shares the route map's track drawing and colours,
    /// but at a thinner scale suited to the country-wide view.
    private func drawRoute(
        _ pointCount: Int, artwork: Artwork, viewport: MapBBox,
        into context: CGContext
    ) {
        let points = artwork.trackGridPoints[0..<pointCount].map(viewport.pixelPosition)

        context.saveGState()
        // Track points follow the top-left-origin frame geometry, as the
        // route map itself draws in.
        context.translateBy(x: 0, y: Double(config.height))
        context.scaleBy(x: 1, y: -1)
        RouteMapRenderer.drawTrack(
            points[...],
            markerRadius: Self.routeMarkerRadius,
            markerBorderWidth: Self.routeMarkerBorderWidth,
            lineWidth: Self.routeLineWidth,
            casingWidth: Self.routeCasingWidth,
            into: context)
        context.restoreGState()
    }

    /// Strokes the sweeping route-area box in a single thin black stroke.
    private func drawBox(_ rect: CGRect, alpha: Double, into context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.setLineJoin(.round)
        context.setStrokeColor(Self.boxColour)
        context.stroke(rect, width: Self.boxLineWidth)
        context.restoreGState()
    }
}
