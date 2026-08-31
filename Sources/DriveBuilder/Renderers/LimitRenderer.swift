import AppKit
import CoreGraphics
import Foundation

/// Builds the speed-limit sign for a journey: a UK-style circular road sign
/// showing the prevailing limit.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct LimitRenderer: DialRenderer {
    static let dialName = "Limit"

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// Artwork rasterized once and reused for every frame.
    struct Artwork {
        /// One rasterized sign per speed limit that occurs in the journey,
        /// loaded from `SVG/limit/<limit>.svg`.
        let signs: [Int: CGImage]

        init(pixelSize: Int, speedLimits: Set<Int>) throws {
            var signs: [Int: CGImage] = [:]
            for limit in speedLimits {
                let bitmap = try SVGRasterizer.bitmap(
                    from: BundledArtwork.svg("\(limit)", dial: "limit"),
                    width: pixelSize,
                    height: pixelSize)
                guard let image = bitmap.cgImage else {
                    throw SVGRasterizerError.undecodableArtwork
                }
                signs[limit] = image
            }
            self.signs = signs
        }
    }

    /// A limit without a matching bundled SVG fails artwork loading up front,
    /// before any frames are rendered.
    func makeArtwork() throws -> Artwork {
        try Artwork(pixelSize: pixelSize, speedLimits: speedLimits)
    }

    /// Draws one frame into `context`: the sign for the record's limit.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        var layers: [LayerCompositor.Layer] = []
        if let sign = artwork.signs[Self.speedLimit(for: record)] {
            layers.append(.init(sign))
        }
        LayerCompositor.draw(layers, into: context, width: pixelSize, height: pixelSize)
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        ["  \(artwork.signs.count) cached signs, \(concurrency)-way compositing"]
    }
}
