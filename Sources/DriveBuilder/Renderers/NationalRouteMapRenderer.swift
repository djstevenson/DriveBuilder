import CoreGraphics
import Foundation

/// Builds the national establishing shot that leads into the route map. A
/// map of Great Britain fills the frame, a box pops in around the area the
/// route map covers, and the camera zooms into that box. The final frame is
/// exactly the route map's own base image, so `RouteMapRenderer` can play
/// its own frames straight on from these with no jump cut.
///
/// The country is rendered here, in a low-detail style (main roads and
/// motorways only); the route's own detailed base image is rendered by
/// `RouteMapRenderer` and passed in, so it's the very same image the route
/// map itself then reveals its track over - rendering it twice risked the
/// external map renderer placing labels slightly differently between the
/// two calls, which is what the jump cut this replaces was. The zoom
/// magnifies the national image while the detailed image fades in over it,
/// in its correct map position, taking over before the national image's
/// pixels are stretched enough to blur.
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
    static let zoomSeconds = 3.0
    // Halved from 1.0: combined with the route map's own introSeconds hold
    // right after it, the two static holds back to back made for too long
    // a pause before the track starts snaking out.
    static let outroSeconds = 0.5

    /// The detailed image fades in over this window of the zoom's eased
    /// progress: starting once the motion is clearly under way, and done
    /// before the national image is magnified enough to look soft.
    static let detailFadeInStart = 0.15
    static let detailFadeInEnd = 0.55

    /// The box fades out over this window of the zoom, before its edges
    /// reach the frame border, so the final frames are clean for the cut.
    static let boxFadeOutStart = 0.5
    static let boxFadeOutEnd = 0.8

    /// Black rather than the track's orange, so the pop-in box that
    /// previews the route's area doesn't read as the same colour as the
    /// route preview drawn over it moments later. Semi-transparent so the
    /// map underneath stays legible through it.
    static let boxColour = CGColor(gray: 0, alpha: 0.5)
    static let boxLineWidth = RouteMapRenderer.trackCasingWidth

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
            + routeUndrawSeconds + zoomSeconds + outroSeconds
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
        /// Pop-in scale of the box, 0 (absent) through 1 (settled), briefly
        /// overshooting 1 on the way.
        var boxScale: Double
        var boxAlpha: Double
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
        let zoomStart = routeUndrawEnd

        let boxScale = RouteMapRenderer.popScale((time - popStart) / Self.boxPopSeconds)
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
            boxScale: boxScale,
            boxAlpha: 1 - Self.ramp(
                zoomProgress, from: Self.boxFadeOutStart, to: Self.boxFadeOutEnd),
            detailAlpha: Self.ramp(
                zoomProgress, from: Self.detailFadeInStart, to: Self.detailFadeInEnd),
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

        if state.routePointCount >= 2 && state.boxAlpha > 0 {
            drawRoute(
                state.routePointCount, artwork: artwork, viewport: state.viewport,
                alpha: state.boxAlpha, into: context)
        }

        if state.boxScale > 0 && state.boxAlpha > 0 {
            drawBox(
                frameRect(of: artwork.detailBBox, under: state.viewport),
                scale: state.boxScale, alpha: state.boxAlpha, into: context)
        }
    }

    /// Draws the revealed prefix of the route preview, projected onto the
    /// current viewport. Shares the route map's track drawing and colours,
    /// but at a thinner scale suited to the country-wide view.
    private func drawRoute(
        _ pointCount: Int, artwork: Artwork, viewport: MapBBox, alpha: Double,
        into context: CGContext
    ) {
        let points = artwork.trackGridPoints[0..<pointCount].map(viewport.pixelPosition)

        context.saveGState()
        context.setAlpha(alpha)
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

    /// Strokes the route-area box, popped about its centre, in a single
    /// semi-transparent black stroke.
    private func drawBox(_ rect: CGRect, scale: Double, alpha: Double, into context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        context.setLineJoin(.round)
        context.setStrokeColor(Self.boxColour)
        context.stroke(rect, width: Self.boxLineWidth)

        context.restoreGState()
    }
}
