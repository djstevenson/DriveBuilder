import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the altitude indicator for a journey: a mountain silhouette with the
/// current altitude below it in feet.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct AltitudeRenderer: DialRenderer {
    static let dialName = "Altitude"

    /// Telemetry `altitude` is metres; the indicator reads in feet.
    static let feetPerMetre = 3.280839895

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 280

    /// Colour and opacity of the square backdrop drawn behind the dial.
    static let backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    /// The altitude to display for a record, in whole feet.
    ///
    /// `Int(x + 0.5)` truncates toward zero, matching the Perl `int(...)`
    /// rounding exactly, including for below-sea-level altitudes.
    static func altitudeFeet(for record: TelemetryRecord) -> Int {
        Int(feetPerMetre * record.altitude + 0.5)
    }

    /// Every altitude the journey needs a text layer for.
    var altitudes: Set<Int> {
        Set(records.map(Self.altitudeFeet(for:)))
    }

    /// Artwork rasterized once and reused for every frame.
    struct Artwork {
        /// Semi-transparent square drawn behind the dial.
        let background: CGImage

        let dial: CGImage

        /// The "N ft" label pre-rendered for each whole-feet altitude that
        /// occurs, so the concurrent frame path is a blit with no text engine.
        /// A journey has a few hundred distinct values.
        let labels: [Int: CGImage]

        init(pixelSize: Int, altitudes: Set<Int>) throws {
            background = try LayerCompositor.solidImage(
                color: AltitudeRenderer.backgroundColor, width: pixelSize, height: pixelSize)

            let bitmap = try SVGRasterizer.bitmap(
                from: BundledArtwork.svg("dial", dial: "altitude"),
                width: pixelSize,
                height: pixelSize)
            guard let image = bitmap.cgImage else {
                throw SVGRasterizerError.undecodableArtwork
            }
            dial = image

            var labels: [Int: CGImage] = [:]
            for altitude in altitudes {
                labels[altitude] = try Artwork.label("\(altitude) ft", pixelSize: pixelSize)
            }
            self.labels = labels
        }

        /// Matches the source SVG text: font-size 14 and baseline y=105 in
        /// the 120-unit viewBox, fill #333, centred on x=60.
        static func label(_ text: String, pixelSize: Int) throws -> CGImage {
            let context = try LayerCompositor.bitmapContext(width: pixelSize, height: pixelSize)
            let scale = CGFloat(pixelSize) / 120

            let font = NSFont.transport(size: 14 * scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes))
            // Positioned by the glyphs' actual ink rather than the advance
            // width and font metrics: Transport's side bearings aren't
            // symmetric and its glyphs don't sit where the metrics imply, so
            // metric-based placement leaves the label visibly off.
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            // The context origin is bottom-left, so the SVG baseline y=105
            // measures 15 viewBox units up from the bottom; the ink is set to
            // rest on it, and centred horizontally on the dial.
            context.textPosition = CGPoint(
                x: CGFloat(pixelSize) / 2 - (ink.minX + ink.width / 2),
                y: 15 * scale - ink.minY)
            CTLineDraw(line, context)

            guard let image = context.makeImage() else {
                throw SVGRasterizerError.contextUnavailable
            }
            return image
        }
    }

    func makeArtwork() throws -> Artwork {
        try Artwork(pixelSize: pixelSize, altitudes: altitudes)
    }

    /// Draws one frame into `context`: static mountain, cached altitude label.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        var layers: [LayerCompositor.Layer] = [.init(artwork.background), .init(artwork.dial)]
        if let label = artwork.labels[Self.altitudeFeet(for: record)] {
            layers.append(.init(label))
        }
        LayerCompositor.draw(layers, into: context, width: pixelSize, height: pixelSize)
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let altitudes = records.prefix(frameCount).map(Self.altitudeFeet(for:))
        return [
            "  altitude \(altitudes.min() ?? 0)-\(altitudes.max() ?? 0) ft",
            "  \(artwork.labels.count) cached labels, \(concurrency)-way compositing",
        ]
    }
}
