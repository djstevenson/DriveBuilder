import AppKit
import CoreGraphics
import Foundation

/// Builds the g-force dial for a journey: a static crosshair dial with a red
/// marker showing the sensed acceleration.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct GForceRenderer: DialRenderer {
    static let dialName = "GForce"

    /// Range of the gauge, in g, from centre to edge.
    static let maxG = 1.0

    /// Radius of the dial's outer circle in viewBox units; must match the
    /// r=50 circle in `SVG/gforce/dial.svg`'s 120-unit viewBox.
    static let dialRadiusUnits = 50.0

    static let markerRadiusUnits = 15.0 / 3.5

    /// Marker red #e31b23, matching the compass needle.
    static let markerColour = CGColor(srgbRed: 0xe3 / 255, green: 0x1b / 255, blue: 0x23 / 255, alpha: 1)

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// Colour and opacity of the square backdrop drawn behind the dial.
    static let backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    /// The sensed force for a record in g, clamped to the dial's range.
    ///
    /// Both axes show the force pinning the driver to one side of their seat,
    /// which is the opposite direction to the raw accelForward/accelLateral
    /// sign conventions: turning right throws you left, accelerating throws
    /// you back, braking throws you forward. Hence the clamp happens on the
    /// raw values and the sign flip on display.
    static func clampedForce(for record: TelemetryRecord) -> (lateral: Double, longitudinal: Double)
    {
        var lateral = record.accelLateral ?? 0
        var longitudinal = record.accelForward ?? 0

        // Peg at the dial's edge rather than draw outside it.
        let magnitude = (lateral * lateral + longitudinal * longitudinal).squareRoot()
        if magnitude > maxG {
            lateral *= maxG / magnitude
            longitudinal *= maxG / magnitude
        }
        return (lateral, longitudinal)
    }

    /// Marker centre in top-left-origin coordinates, matching the Perl/Cairo
    /// frame: braking (negative accelForward) puts the marker above centre,
    /// turning right (positive accelLateral) puts it left of centre.
    static func markerPosition(for record: TelemetryRecord, pixelSize: Int) -> CGPoint {
        let force = clampedForce(for: record)
        let centre = Double(pixelSize) / 2
        let radius = Double(pixelSize) * dialRadiusUnits / 120
        return CGPoint(
            x: centre - (force.lateral / maxG) * radius,
            y: centre + (force.longitudinal / maxG) * radius)
    }

    /// Artwork rasterized once and reused for every frame.
    struct Artwork {
        /// Semi-transparent square drawn behind the dial.
        let background: CGImage

        let dial: CGImage

        init(pixelSize: Int) throws {
            background = try LayerCompositor.solidImage(
                color: GForceRenderer.backgroundColor, width: pixelSize, height: pixelSize)

            let bitmap = try SVGRasterizer.bitmap(
                from: BundledArtwork.svg("dial", dial: "gforce"),
                width: pixelSize,
                height: pixelSize)
            guard let image = bitmap.cgImage else {
                throw SVGRasterizerError.undecodableArtwork
            }
            dial = image
        }
    }

    func makeArtwork() throws -> Artwork {
        try Artwork(pixelSize: pixelSize)
    }

    /// Draws one frame into `context`: static dial, then the marker as plain
    /// geometry, which is cheaper than compositing a pre-rendered layer.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        LayerCompositor.draw(
            [.init(artwork.background), .init(artwork.dial)],
            into: context, width: pixelSize, height: pixelSize)

        let position = Self.markerPosition(for: record, pixelSize: pixelSize)
        let radius = Double(pixelSize) * Self.markerRadiusUnits / 120
        context.setFillColor(Self.markerColour)
        context.fillEllipse(
            in: CGRect(
                x: position.x - radius,
                // The context origin is bottom-left; markerPosition is top-left.
                y: Double(pixelSize) - position.y - radius,
                width: radius * 2,
                height: radius * 2))
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let peak = records.prefix(frameCount)
            .map { record in
                let force = Self.clampedForce(for: record)
                return (force.lateral * force.lateral
                    + force.longitudinal * force.longitudinal).squareRoot()
            }
            .max() ?? 0
        return [
            String(format: "  peak %.2f g, %d-way compositing", peak, concurrency)
        ]
    }
}
