import AppKit
import CoreGraphics
import Foundation

/// Builds the zoomed progress map for a journey: a detailed map window
/// panning under a car marker fixed at the centre of the frame.
///
/// Unlike the dial renderers this one does not conform to `DialRenderer`:
/// it renders three output frames per telemetry record (30 fps rather than
/// the 10 Hz native telemetry rate, interpolating between records) because
/// a panning map makes stepping motion far more visible than a rotating
/// needle does.
struct ProgressMapZoomedRenderer {
    static let dialName = "ProgressMapZoomed"

    /// The frame size the map's proportions were designed at; rendering at
    /// another size scales the whole picture rather than changing the view.
    static let designPixelSize = 420.0

    /// Metres shown per pixel at the design size: much more detail than an
    /// overview map, since only a small window around the car is shown.
    static let designMetresPerPixel = 2.0

    /// Output frames per telemetry record, and the matching frame rate for
    /// telemetry sampled at 10 Hz.
    static let subframesPerRecord = 3
    static let framesPerSecond: Int32 = 30

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// Physical size of each on-demand map tile, in metres. A route can be
    /// arbitrarily long, so rather than render it all at full detail (which
    /// is wasteful and can exceed bitmap size limits), modest tiles are
    /// rendered around the car and replaced as the car nears their edge.
    /// Must be comfortably bigger than the output window (840 m of ground).
    /// Sized to keep the decoded tile modest — 10 km is ~8,400 px and
    /// ~280 MB at the 708 px production size, where 30 km was 2.6 GB — while
    /// still amortizing maprender.py's fixed startup over ~9 km of travel.
    var tileSizeMetres = 10_000.0

    let tileRenderer: any MapTileRenderer

    /// Metres per pixel at the actual frame size: the window always covers
    /// the same ground as at the design size, so a bigger frame shows the
    /// same picture at a larger scale.
    var metresPerPixel: Double {
        Self.designMetresPerPixel * Self.designPixelSize / Double(pixelSize)
    }

    /// How close the car can get to a tile's edge before the next frame
    /// switches to a tile centred on the car: half the output window, so
    /// the window always stays inside the tile.
    var tileMarginMetres: Double {
        Double(pixelSize) / 2 * metresPerPixel
    }

    // MARK: - Interpolation

    /// Interpolates headings across the 0/360 wrap by the shortest arc.
    static func interpolateHeading(from previous: Double, to current: Double, fraction: Double)
        -> Double
    {
        var delta = current - previous
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return previous + delta * fraction
    }

    /// A record `fraction` of the way from `previous` to `current`.
    static func interpolate(
        _ previous: TelemetryRecord, _ current: TelemetryRecord, fraction: Double
    ) -> TelemetryRecord {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return TelemetryRecord(
            id: previous.id,
            journeyID: previous.journeyID,
            timestamp: previous.timestamp.addingTimeInterval(
                current.timestamp.timeIntervalSince(previous.timestamp) * fraction),
            latitude: lerp(previous.latitude, current.latitude),
            longitude: lerp(previous.longitude, current.longitude),
            altitude: lerp(previous.altitude, current.altitude),
            speed: lerp(previous.speed, current.speed),
            heading: interpolateHeading(
                from: previous.heading, to: current.heading, fraction: fraction),
            accelForward: nil,
            accelLateral: nil,
            speedLimit: previous.speedLimit,
            file: previous.file ?? current.file,
            source: "Interpolated")
    }

    // MARK: - Frames and tiles

    /// One output frame: the car's grid position and heading.
    struct Frame: Equatable {
        let grid: OSGB.GridPoint
        let heading: Double
    }

    static func frame(for record: TelemetryRecord) -> Frame {
        Frame(
            grid: OSGB.gridPoint(latitude: record.latitude, longitude: record.longitude),
            heading: record.heading)
    }

    /// The full output frame sequence: each record preceded by the subframes
    /// interpolated from its predecessor.
    var frames: [Frame] {
        var frames: [Frame] = []
        frames.reserveCapacity(max(records.count * Self.subframesPerRecord - 2, 0))
        var previous: TelemetryRecord?
        for record in records {
            if let previous {
                for step in 1..<Self.subframesPerRecord {
                    let fraction = Double(step) / Double(Self.subframesPerRecord)
                    frames.append(
                        Self.frame(for: Self.interpolate(previous, record, fraction: fraction)))
                }
            }
            frames.append(Self.frame(for: record))
            previous = record
        }
        return frames
    }

    /// A tile bounding box centred on a grid position.
    func tileBBox(centredOn grid: OSGB.GridPoint) -> MapBBox {
        let half = tileSizeMetres / 2
        let sizePixels = Int((tileSizeMetres / metresPerPixel).rounded(.up))
        return MapBBox(
            minEasting: grid.easting - half,
            minNorthing: grid.northing - half,
            maxEasting: grid.easting + half,
            maxNorthing: grid.northing + half,
            width: sizePixels,
            height: sizePixels)
    }

    /// Walks the frames deciding which tile each one draws from: a frame
    /// reuses the previous frame's tile until the car comes within the
    /// margin of its edge, then starts a fresh tile centred on the car.
    ///
    /// Precomputing the schedule keeps per-frame drawing pure so frames can
    /// be composited concurrently, where the Perl walked the same rule with
    /// a mutable one-tile cache.
    func tileSchedule(for frames: [Frame]) -> (tiles: [MapBBox], frameTile: [Int]) {
        var tiles: [MapBBox] = []
        var frameTile: [Int] = []
        frameTile.reserveCapacity(frames.count)
        let margin = tileMarginMetres

        for frame in frames {
            if let tile = tiles.last,
                frame.grid.easting >= tile.minEasting + margin,
                frame.grid.easting <= tile.maxEasting - margin,
                frame.grid.northing >= tile.minNorthing + margin,
                frame.grid.northing <= tile.maxNorthing - margin
            {
                frameTile.append(tiles.count - 1)
            } else {
                tiles.append(tileBBox(centredOn: frame.grid))
                frameTile.append(tiles.count - 1)
            }
        }
        return (tiles, frameTile)
    }

    // MARK: - Drawing

    /// The car marker, pointing north.
    func carImage() throws -> CGImage {
        try CarMarker.image(scaledFor: pixelSize)
    }

    /// Draws one frame: the tile window centred on the car, then the car
    /// marker rotated to the heading.
    func draw(
        _ frame: Frame, tile: CGImage, bbox: MapBBox, car: CGImage, into context: CGContext
    ) {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let centre = Double(pixelSize) / 2

        // The car's pixel within the tile, in top-left-origin tile coordinates.
        let position = bbox.pixelPosition(of: frame.grid)

        // Position the whole tile so that pixel lands at the frame centre,
        // converting to the context's bottom-left origin. Drawing with a
        // fractional offset keeps the pan sub-pixel smooth.
        let tileRect = CGRect(
            x: centre - position.x,
            y: Double(pixelSize) - (centre - position.y) - Double(bbox.height),
            width: Double(bbox.width),
            height: Double(bbox.height))

        context.clear(bounds)
        context.draw(tile, in: tileRect)
        CarMarker.draw(
            car, at: CGPoint(x: centre, y: centre), headingDegrees: frame.heading,
            into: context, frameHeight: pixelSize)
    }

    // MARK: - Movie

    /// Renders the movie at 30 fps: three frames per telemetry record.
    ///
    /// `frameLimit` counts output frames. Map tiles are rendered up front by
    /// the external renderer — only the ones the limited frame range needs.
    func writeMovie(
        to url: URL,
        frameLimit: Int? = nil,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws {
        var frames = self.frames
        if let frameLimit, frameLimit < frames.count {
            frames = Array(frames.prefix(frameLimit))
        }
        let (tileBoxes, frameTile) = tileSchedule(for: frames)

        print(
            "\(Self.dialName): \(records.count) telemetry records, "
                + "rendering \(frames.count) frames at \(Self.framesPerSecond) fps.")
        print(
            String(
                format: "  %d map tiles at %.2f m/px, %d-way compositing",
                tileBoxes.count, metresPerPixel, concurrency))

        let car = try carImage()
        var tiles: [CGImage] = []
        for (index, bbox) in tileBoxes.enumerated() {
            FileHandle.standardError.write(
                Data("  rendering tile \(index + 1)/\(tileBoxes.count)\n".utf8))
            tiles.append(try tileRenderer.renderMap(bbox))
        }

        var writer = AlphaMovieWriter(
            url: url, width: pixelSize, height: pixelSize,
            framesPerSecond: Self.framesPerSecond)
        writer.concurrency = concurrency

        let started = ContinuousClock.now
        try await writer.write(
            frameCount: frames.count,
            progress: { done in
                guard done % 5000 == 0 || done == frames.count else { return }
                FileHandle.standardError.write(Data("  \(done)/\(frames.count) frames\n".utf8))
            },
            drawFrame: { index, context in
                let tileIndex = frameTile[index]
                draw(
                    frames[index], tile: tiles[tileIndex], bbox: tileBoxes[tileIndex],
                    car: car, into: context)
            })

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs (%.3f ms/frame) to %@",
                Double(frames.count) / Double(Self.framesPerSecond), pixelSize, pixelSize,
                seconds, seconds * 1000 / Double(max(frames.count, 1)),
                url.path(percentEncoded: false)))
    }
}
