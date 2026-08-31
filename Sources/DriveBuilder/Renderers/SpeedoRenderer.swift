import AppKit
import CoreGraphics
import Foundation

/// Builds the speedometer dial for a journey.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct SpeedoRenderer: DialRenderer {
    static let dialName = "Speedo"

    /// Telemetry `speed` is km/h; the dial is calibrated in mph.
    static let mphPerKPH = 0.6213712

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// Needle angle for a speed in mph. 40 mph points straight up, and the
    /// 0-80 mph span is spread over 260 degrees.
    static func angle(forMPH speed: Double) -> Double {
        (speed - 40.0) / 80.0 * 260.0
    }

    /// The speed the dial should show for a record, in mph.
    ///
    /// Clamped to the prevailing limit so the finished video never reports an
    /// excess over the posted limit.
    static func indicatedMPH(for record: TelemetryRecord) -> Double {
        let limit = Double(record.speedLimit ?? assumedSpeedLimit)
        return min(record.speed * mphPerKPH, limit)
    }

    /// Artwork rasterized once and reused for every frame.
    struct Artwork {
        let dial: CGImage
        let needle: CGImage

        /// The limit marker pre-rotated for each speed limit that occurs.
        ///
        /// Its angle depends only on the limit, and a journey has a handful of
        /// distinct limits, so caching turns a per-frame resample into a blit.
        let limitMarkers: [Int: CGImage]

        init(pixelSize: Int, speedLimits: Set<Int>) throws {
            func layer(_ name: String) throws -> CGImage {
                let bitmap = try SVGRasterizer.bitmap(
                    from: BundledArtwork.svg(name, dial: "speedo"),
                    width: pixelSize,
                    height: pixelSize)
                guard let image = bitmap.cgImage else {
                    throw SVGRasterizerError.undecodableArtwork
                }
                return image
            }

            dial = try layer("dial")
            needle = try layer("needle")

            let marker = try layer("limit")
            var rotated: [Int: CGImage] = [:]
            for limit in speedLimits {
                rotated[limit] = try LayerCompositor.rotatedImage(
                    marker,
                    degrees: SpeedoRenderer.angle(forMPH: Double(limit)),
                    width: pixelSize,
                    height: pixelSize)
            }
            limitMarkers = rotated
        }
    }

    func makeArtwork() throws -> Artwork {
        try Artwork(pixelSize: pixelSize, speedLimits: speedLimits)
    }

    /// Draws one frame into `context`: static dial, cached limit marker, rotated needle.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        var layers: [LayerCompositor.Layer] = [.init(artwork.dial)]
        if let marker = artwork.limitMarkers[Self.speedLimit(for: record)] {
            layers.append(.init(marker))
        }
        layers.append(
            .init(artwork.needle, rotationDegrees: Self.angle(forMPH: Self.indicatedMPH(for: record)))
        )
        LayerCompositor.draw(layers, into: context, width: pixelSize, height: pixelSize)
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let speeds = records.prefix(frameCount).map(Self.indicatedMPH(for:))
        let lowest = speeds.min() ?? 0
        let highest = speeds.max() ?? 0
        return [
            String(
                format: "  indicated speed %.1f-%.1f mph, needle %.1f° to %.1f°",
                lowest, highest, Self.angle(forMPH: lowest), Self.angle(forMPH: highest)),
            "  \(artwork.limitMarkers.count) cached limit markers, \(concurrency)-way compositing",
        ]
    }
}
