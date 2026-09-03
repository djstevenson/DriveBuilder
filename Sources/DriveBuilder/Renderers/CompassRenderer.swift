import AppKit
import CoreGraphics
import Foundation

/// Builds the compass dial for a journey: a static rose with a needle rotated
/// to the telemetry heading.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct CompassRenderer: DialRenderer {
    static let dialName = "Compass"

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 280

    /// Colour and opacity of the square backdrop drawn behind the dial.
    static let backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    /// Artwork rasterized once and reused for every frame. The needle is drawn
    /// pointing north and rotated per frame.
    struct Artwork {
        /// Semi-transparent square drawn behind the dial.
        let background: CGImage

        let dial: CGImage
        let needle: CGImage

        init(pixelSize: Int) throws {
            background = try LayerCompositor.solidImage(
                color: CompassRenderer.backgroundColor, width: pixelSize, height: pixelSize)

            func layer(_ name: String) throws -> CGImage {
                let bitmap = try SVGRasterizer.bitmap(
                    from: BundledArtwork.svg(name, dial: "compass"),
                    width: pixelSize,
                    height: pixelSize)
                guard let image = bitmap.cgImage else {
                    throw SVGRasterizerError.undecodableArtwork
                }
                return image
            }

            dial = try layer("dial")
            needle = try layer("needle")
        }
    }

    func makeArtwork() throws -> Artwork {
        try Artwork(pixelSize: pixelSize)
    }

    /// Draws one frame into `context`: static dial, needle rotated clockwise
    /// by the record's heading in degrees (0 = north).
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        LayerCompositor.draw(
            [
                .init(artwork.background),
                .init(artwork.dial),
                .init(artwork.needle, rotationDegrees: record.heading),
            ],
            into: context, width: pixelSize, height: pixelSize)
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        ["  \(concurrency)-way compositing"]
    }
}
