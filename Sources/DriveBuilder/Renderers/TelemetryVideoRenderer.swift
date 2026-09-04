import AppKit
import CoreGraphics
import Foundation

/// Composites every telemetry dial into a single movie, frame by frame,
/// replacing the ffmpeg overlay pass that used to stitch the individual dial
/// movies together.
///
/// The layout matches that ffmpeg filter graph: a 2x2 grid of dials up top
/// (speedo, g-force / compass, altitude), the zoomed progress map below it,
/// and the overview progress map at the bottom, all over a transparent
/// background. At the default sizes that is a 708x2160 canvas.
///
/// Everything renders at the telemetry rate: one output frame per record.
/// The zoomed map's own movie interpolates to 30 fps, but here it draws the
/// un-interpolated record positions so all six dials share a frame clock.
struct TelemetryVideoRenderer {
    static let dialName = "Telemetry"

    let records: [TelemetryRecord]

    /// Edge length of each dial in the 2x2 grid, in pixels.
    let dialPixelSize: Int

    /// Edge length of the two progress maps, in pixels. Also the canvas
    /// width, since the maps span the full width.
    let mapPixelSize: Int

    var speedo: SpeedoRenderer
    var gforce: GForceRenderer
    var compass: CompassRenderer
    var altitude: AltitudeRenderer
    var progressMap: ProgressMapRenderer
    var progressMapZoomed: ProgressMapZoomedRenderer

    init(
        records: [TelemetryRecord],
        dialPixelSize: Int = 345,
        mapPixelSize: Int = 708,
        tileRenderer: any MapTileRenderer
    ) {
        self.records = records
        self.dialPixelSize = dialPixelSize
        self.mapPixelSize = mapPixelSize
        speedo = SpeedoRenderer(records: records, pixelSize: dialPixelSize)
        gforce = GForceRenderer(records: records, pixelSize: dialPixelSize)
        compass = CompassRenderer(records: records, pixelSize: dialPixelSize)
        altitude = AltitudeRenderer(records: records, pixelSize: dialPixelSize)
        progressMap = ProgressMapRenderer(
            records: records, pixelSize: mapPixelSize, tileRenderer: tileRenderer)
        progressMapZoomed = ProgressMapZoomedRenderer(
            records: records, pixelSize: mapPixelSize, tileRenderer: tileRenderer)
    }

    // MARK: - Layout

    /// Space between cells: the maps are sized as two dials plus this gap,
    /// so it falls out of the two edge lengths. 18 px at the default sizes.
    var gap: Int { mapPixelSize - 2 * dialPixelSize }

    /// Distance from one grid cell's origin to the next: a dial plus a gap.
    private var gridStep: Int { dialPixelSize + gap }

    var width: Int { mapPixelSize }

    /// Dial grid, zoomed map, overview map, with a gap between each. 2160
    /// at the default sizes, matching a native-4K frame height.
    var height: Int { 2 * gridStep + 2 * mapPixelSize + gap }

    /// Top-left corners of each cell, in top-left-origin canvas coordinates,
    /// mirroring the ffmpeg overlay positions.
    private var speedoOrigin: CGPoint { CGPoint(x: 0, y: 0) }
    private var gforceOrigin: CGPoint { CGPoint(x: gridStep, y: 0) }
    private var compassOrigin: CGPoint { CGPoint(x: 0, y: gridStep) }
    private var altitudeOrigin: CGPoint { CGPoint(x: gridStep, y: gridStep) }
    private var zoomedMapOrigin: CGPoint { CGPoint(x: 0, y: 2 * gridStep) }
    private var progressMapOrigin: CGPoint {
        CGPoint(x: 0, y: 2 * gridStep + mapPixelSize + gap)
    }

    // MARK: - Artwork

    /// Everything rasterized once and reused for every frame: each dial's
    /// own artwork, plus the zoomed map's frame positions, tile schedule,
    /// and rendered tiles.
    struct Artwork {
        let speedo: SpeedoRenderer.Artwork
        let gforce: GForceRenderer.Artwork
        let compass: CompassRenderer.Artwork
        let altitude: AltitudeRenderer.Artwork
        let progressMap: ProgressMapRenderer.Artwork
        let zoomedFrames: [ProgressMapZoomedRenderer.Frame]
        let zoomedTileBoxes: [MapBBox]
        let zoomedFrameTile: [Int]
        let zoomedTiles: [CGImage]
        let car: CGImage
    }

    /// Builds the artwork for the first `frameCount` records. Map tiles are
    /// rendered up front by the external renderer — only the ones the
    /// limited frame range needs.
    func makeArtwork(frameCount: Int) throws -> Artwork {
        // One zoomed-map frame per record, skipping the 30 fps interpolation.
        let zoomedFrames = records.prefix(frameCount)
            .map(ProgressMapZoomedRenderer.frame(for:))
        let (tileBoxes, frameTile) = progressMapZoomed.tileSchedule(for: zoomedFrames)

        var tiles: [CGImage] = []
        for (index, bbox) in tileBoxes.enumerated() {
            FileHandle.standardError.write(
                Data("  rendering tile \(index + 1)/\(tileBoxes.count)\n".utf8))
            tiles.append(try progressMapZoomed.tileRenderer.renderMap(bbox))
        }

        return Artwork(
            speedo: try speedo.makeArtwork(),
            gforce: try gforce.makeArtwork(),
            compass: try compass.makeArtwork(),
            altitude: try altitude.makeArtwork(),
            progressMap: try progressMap.makeArtwork(),
            zoomedFrames: zoomedFrames,
            zoomedTileBoxes: tileBoxes,
            zoomedFrameTile: frameTile,
            zoomedTiles: tiles,
            car: try progressMapZoomed.carImage())
    }

    // MARK: - Drawing

    /// Draws one composited frame into `context`.
    ///
    /// Called concurrently with a distinct context per thread, so it must
    /// not touch shared mutable state.
    func draw(frameIndex: Int, into context: CGContext, artwork: Artwork) {
        // Contexts are reused across frames; without the clear the previous
        // frame shows through the gaps between cells.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let record = records[frameIndex]
        inCell(at: speedoOrigin, size: dialPixelSize, in: context) {
            speedo.draw(record, into: $0, artwork: artwork.speedo)
        }
        inCell(at: gforceOrigin, size: dialPixelSize, in: context) {
            gforce.draw(record, into: $0, artwork: artwork.gforce)
        }
        inCell(at: compassOrigin, size: dialPixelSize, in: context) {
            compass.draw(record, into: $0, artwork: artwork.compass)
        }
        inCell(at: altitudeOrigin, size: dialPixelSize, in: context) {
            altitude.draw(record, into: $0, artwork: artwork.altitude)
        }
        inCell(at: zoomedMapOrigin, size: mapPixelSize, in: context) {
            let tileIndex = artwork.zoomedFrameTile[frameIndex]
            progressMapZoomed.draw(
                artwork.zoomedFrames[frameIndex],
                tile: artwork.zoomedTiles[tileIndex],
                bbox: artwork.zoomedTileBoxes[tileIndex],
                car: artwork.car,
                into: $0)
        }
        inCell(at: progressMapOrigin, size: mapPixelSize, in: context) {
            progressMap.draw(record, into: $0, artwork: artwork.progressMap)
        }
    }

    /// Runs `body` with the context translated so the cell's bottom-left
    /// corner is the origin, and clipped to the cell.
    ///
    /// The dial renderers all draw relative to the origin of a context they
    /// expect to own, so translation is all the compositing takes. The clip
    /// matters for the zoomed map, whose tile is far larger than its window
    /// and relied on the frame edge to crop it.
    private func inCell(
        at origin: CGPoint, size: Int, in context: CGContext, _ body: (CGContext) -> Void
    ) {
        context.saveGState()
        // Cell origins are top-left of a top-left-origin canvas; the context
        // origin is bottom-left.
        context.translateBy(x: origin.x, y: Double(height) - origin.y - Double(size))
        context.clip(to: CGRect(x: 0, y: 0, width: size, height: size))
        body(context)
        context.restoreGState()
    }

    // MARK: - Movie

    /// Renders one composited frame per telemetry record into a ProRes 4444
    /// movie with a transparent background.
    ///
    /// Telemetry is sampled every 100 ms, so one record is one frame at 10 fps.
    func writeMovie(
        to url: URL,
        framesPerSecond: Int32 = 10,
        frameLimit: Int? = nil,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws {
        let frameCount = min(records.count, frameLimit ?? records.count)

        print(
            "\(Self.dialName): \(records.count) telemetry records, "
                + "rendering \(frameCount) composited \(width)x\(height) frames.")

        let artwork = try makeArtwork(frameCount: frameCount)
        print(
            String(
                format: "  %d zoomed-map tiles at %.2f m/px, %d-way compositing",
                artwork.zoomedTiles.count, progressMapZoomed.metresPerPixel, concurrency))

        var writer = AlphaMovieWriter(
            url: url, width: width, height: height, framesPerSecond: framesPerSecond)
        writer.concurrency = concurrency

        let started = ContinuousClock.now
        try await writer.write(
            frameCount: frameCount,
            progress: { done in
                guard done % 1000 == 0 || done == frameCount else { return }
                FileHandle.standardError.write(Data("  \(done)/\(frameCount) frames\n".utf8))
            },
            drawFrame: { index, context in
                draw(frameIndex: index, into: context, artwork: artwork)
            })

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs (%.3f ms/frame) to %@",
                Double(frameCount) / Double(framesPerSecond), width, height,
                seconds, seconds * 1000 / Double(max(frameCount, 1)),
                url.path(percentEncoded: false)))
    }
}
