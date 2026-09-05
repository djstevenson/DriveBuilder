import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the altitude indicator for a journey: latitude, longitude, and
/// altitude as text, each on its own opaque box so the numbers stay legible
/// whatever the dashcam footage behind the dial is doing.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct AltitudeRenderer: DialRenderer {
    static let dialName = "Altitude"

    /// Telemetry `altitude` is metres; the indicator reads in feet.
    static let feetPerMetre = 3.280839895

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 345

    /// Fully opaque, unlike the other dials' translucent backdrop: the box
    /// is what keeps the text readable, so it can't let footage show through.
    static let boxColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Doubled from an initial 13pt: at that size the text read as illegible
    /// once encoded down to 1080p or 720p.
    static let fontSize = 26.0
    static let cornerRadius = 4.0
    static let textPadding = 10.0
    static let rowHeight = 25.0
    static let rowGap = 4.0
    static let topMargin = 6.0
    static let boxLeft = 14.0

    /// The altitude to display for a record, in whole feet.
    ///
    /// `Int(x + 0.5)` truncates toward zero, matching the Perl `int(...)`
    /// rounding exactly, including for below-sea-level altitudes.
    static func altitudeFeet(for record: TelemetryRecord) -> Int {
        Int(feetPerMetre * record.altitude + 0.5)
    }

    static func latitudeText(_ record: TelemetryRecord) -> String {
        String(format: "LAT %.4f", record.latitude)
    }

    static func longitudeText(_ record: TelemetryRecord) -> String {
        String(format: "LON %.4f", record.longitude)
    }

    static func altitudeText(_ record: TelemetryRecord) -> String {
        "ALT \(altitudeFeet(for: record)) ft"
    }

    /// The three rows drawn for a record, top to bottom.
    static func rowTexts(for record: TelemetryRecord) -> [String] {
        [latitudeText(record), longitudeText(record), altitudeText(record)]
    }

    /// A row's bottom edge, in the nominal 120-unit viewBox the other dials'
    /// artwork uses, counted down from the top so a fourth row (an odometer)
    /// can be added below later without disturbing these three.
    static func rowBottom(_ index: Int) -> Double {
        120 - topMargin - Double(index + 1) * rowHeight - Double(index) * rowGap
    }

    /// Artwork rasterized once and reused for every frame: just the font and
    /// each row's box width. The width is fixed to whatever that journey's
    /// most extreme value on that line needs, so the box never resizes from
    /// frame to frame.
    struct Artwork {
        let font: NSFont

        /// Box width per row, in the same 120-unit viewBox as `rowBottom`.
        let boxWidths: [Double]

        init(records: [TelemetryRecord]) {
            // Kept as a local rather than assigned to `self.font` up front:
            // the nested `inkWidth` below captures it, and a nested function
            // can't capture `self` before every stored property is set.
            let font = NSFont.transport(size: AltitudeRenderer.fontSize)

            func inkWidth(_ text: String) -> Double {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font]))
                return Double(CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
            }

            let latitudes = records.map(\.latitude)
            let longitudes = records.map(\.longitude)
            let altitudes = records.map(AltitudeRenderer.altitudeFeet(for:))

            let latWidth = max(
                inkWidth(String(format: "LAT %.4f", latitudes.min() ?? 0)),
                inkWidth(String(format: "LAT %.4f", latitudes.max() ?? 0)))
            let lonWidth = max(
                inkWidth(String(format: "LON %.4f", longitudes.min() ?? 0)),
                inkWidth(String(format: "LON %.4f", longitudes.max() ?? 0)))
            let altWidth = max(
                inkWidth("ALT \(altitudes.min() ?? 0) ft"),
                inkWidth("ALT \(altitudes.max() ?? 0) ft"))

            self.font = font
            boxWidths = [latWidth, lonWidth, altWidth].map { $0 + 2 * AltitudeRenderer.textPadding }
        }
    }

    func makeArtwork() throws -> Artwork {
        Artwork(records: records)
    }

    /// Draws one frame into `context`: three opaque rounded boxes, one per
    /// line of text.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        let scale = CGFloat(pixelSize) / 120
        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        for (index, text) in Self.rowTexts(for: record).enumerated() {
            drawRow(
                text, boxWidth: artwork.boxWidths[index], bottom: Self.rowBottom(index),
                scale: scale, font: artwork.font, into: context)
        }
    }

    /// Matches the source SVG text conventions elsewhere: positioned by the
    /// glyphs' actual ink rather than the advance width and font metrics,
    /// since Transport's side bearings aren't symmetric and its glyphs don't
    /// sit where the metrics imply.
    private func drawRow(
        _ text: String, boxWidth: Double, bottom: Double, scale: CGFloat, font: NSFont,
        into context: CGContext
    ) {
        let boxRect = CGRect(
            x: Self.boxLeft * scale, y: bottom * scale,
            width: boxWidth * scale, height: Self.rowHeight * scale)

        context.setFillColor(Self.boxColor)
        context.addPath(
            CGPath(
                roundedRect: boxRect, cornerWidth: Self.cornerRadius * scale,
                cornerHeight: Self.cornerRadius * scale, transform: nil))
        context.fillPath()

        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

        context.setFillColor(Self.textColor)
        context.textPosition = CGPoint(
            x: boxRect.minX + Self.textPadding * scale - ink.minX,
            y: boxRect.minY + (boxRect.height - ink.height) / 2 - ink.minY)
        CTLineDraw(line, context)
    }

    func summaryLines(artwork: Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let altitudes = records.prefix(frameCount).map(Self.altitudeFeet(for:))
        return [
            "  altitude \(altitudes.min() ?? 0)-\(altitudes.max() ?? 0) ft",
            "  \(concurrency)-way compositing",
        ]
    }
}
