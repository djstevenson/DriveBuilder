import AppKit
import CoreGraphics
import Foundation

/// A renderer that turns a journey's telemetry into one movie frame per record.
///
/// Conformers supply the pre-rasterized artwork and per-frame drawing; the
/// protocol provides the shared speed-limit semantics, still-frame path, and
/// movie-writing pipeline.
protocol DialRenderer {
    /// Artwork rasterized once and reused for every frame.
    associatedtype Artwork

    /// Name used to prefix log output, e.g. "Speedo".
    static var dialName: String { get }

    var records: [TelemetryRecord] { get }

    /// Edge length of the rendered frame, in pixels.
    var pixelSize: Int { get }

    func makeArtwork() throws -> Artwork

    /// Draws one frame for `record` into `context`.
    ///
    /// Called concurrently with a distinct context per thread, so it must not
    /// touch shared mutable state.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork)

    /// Renderer-specific lines for the pre-render summary, already indented.
    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String]
}

extension DialRenderer {
    /// Used when a record has no recorded speed limit.
    static var assumedSpeedLimit: Int { 60 }

    static func speedLimit(for record: TelemetryRecord) -> Int {
        record.speedLimit ?? assumedSpeedLimit
    }

    /// Every speed limit the journey needs artwork for.
    var speedLimits: Set<Int> {
        Set(records.map(Self.speedLimit(for:))).union([Self.assumedSpeedLimit])
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        []
    }

    /// One composited frame as a bitmap. For stills, rather than the video path.
    func frame(for record: TelemetryRecord, artwork: Artwork) throws -> NSBitmapImageRep {
        let canvas = try SVGRasterizer.blankBitmap(width: pixelSize, height: pixelSize)
        try SVGRasterizer.withGraphicsContext(over: canvas) { context in
            draw(record, into: context.cgContext, artwork: artwork)
        }
        return canvas
    }

    /// Renders one frame per telemetry record into a ProRes 4444 movie with a
    /// transparent background.
    ///
    /// Telemetry is sampled every 100 ms, so one record is one frame at 10 fps.
    func writeMovie(
        to url: URL,
        framesPerSecond: Int32 = 10,
        frameLimit: Int? = nil,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws {
        let artwork = try makeArtwork()
        let frameCount = min(records.count, frameLimit ?? records.count)

        print("\(Self.dialName): \(records.count) telemetry records, rendering \(frameCount) frames.")
        for line in summaryLines(artwork: artwork, frameCount: frameCount, concurrency: concurrency) {
            print(line)
        }

        var writer = AlphaMovieWriter(
            url: url, width: pixelSize, height: pixelSize, framesPerSecond: framesPerSecond)
        writer.concurrency = concurrency

        let started = ContinuousClock.now
        try await writer.write(
            frameCount: frameCount,
            progress: { done in
                guard done % 5000 == 0 || done == frameCount else { return }
                FileHandle.standardError.write(Data("  \(done)/\(frameCount) frames\n".utf8))
            },
            drawFrame: { index, context in
                draw(records[index], into: context, artwork: artwork)
            })

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs (%.3f ms/frame) to %@",
                Double(frameCount) / Double(framesPerSecond), pixelSize, pixelSize,
                seconds, seconds * 1000 / Double(max(frameCount, 1)),
                url.path(percentEncoded: false)))
    }
}
