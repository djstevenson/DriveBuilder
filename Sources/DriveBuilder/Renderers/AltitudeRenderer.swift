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

    /// Upper limit on the font size: a full 4-decimal "LON -179.9999" doesn't
    /// fit a fixed-width box at this size, so `Artwork` shrinks it just
    /// enough for the journey's actual extremes to fit rather than using it
    /// outright.
    static let fontSize = 26.0
    static let minFontSize = 10.0
    static let cornerRadius = 4.0

    /// Gap between each box and the edge of the frame. Fixed regardless of
    /// the text, so the gap matches on both sides instead of the box
    /// growing to fit its content and leaving a lopsided margin.
    static let boxMargin = 7.0
    /// Roughly 20px at the default 345px frame size.
    static let boxLeft = boxMargin
    static let boxWidth = 120 - 2 * boxMargin

    /// Padding between the text and the edges of its (fixed-width) box.
    static let textPadding = 5.0

    static let rowHeight = 25.0
    static let rowGap = 4.0
    static let topMargin = 6.0

    /// The altitude to display for a record, in whole feet.
    ///
    /// `Int(x + 0.5)` truncates toward zero, matching the Perl `int(...)`
    /// rounding exactly, including for below-sea-level altitudes.
    static func altitudeFeet(for record: TelemetryRecord) -> Int {
        Int(feetPerMetre * record.altitude + 0.5)
    }

    /// No "LAT" label and no sign: the row's position already says what it
    /// is, and a trailing hemisphere letter says which way the sign would
    /// have, both more cheaply than the words and the "-" would have.
    ///
    /// Split out from the `TelemetryRecord`-based functions below so
    /// `Artwork` can measure the journey's extreme values directly, without
    /// duplicating the format strings (and risking them drifting apart).
    static func latitudeText(_ latitude: Double) -> String {
        String(format: "%.4f", abs(latitude)) + (latitude < 0 ? "S" : "N")
    }

    static func longitudeText(_ longitude: Double) -> String {
        String(format: "%.4f", abs(longitude)) + (longitude < 0 ? "W" : "E")
    }

    /// No "ALT" label either, for the same reason - an up arrow marks the
    /// row instead. Transport has no arrow glyph, so this falls back to a
    /// system font for that one character; Core Text substitutes it
    /// automatically mid-line.
    static func altitudeText(feet: Int) -> String {
        "↑\(feet) ft"
    }

    static func latitudeText(_ record: TelemetryRecord) -> String {
        latitudeText(record.latitude)
    }

    static func longitudeText(_ record: TelemetryRecord) -> String {
        longitudeText(record.longitude)
    }

    static func altitudeText(_ record: TelemetryRecord) -> String {
        altitudeText(feet: altitudeFeet(for: record))
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

    /// Artwork rasterized once and reused for every frame: just the font,
    /// sized as large as possible up to `fontSize` while still fitting the
    /// journey's most extreme latitude, longitude, and altitude inside the
    /// fixed-width box.
    struct Artwork {
        let font: NSFont

        init(records: [TelemetryRecord]) {
            func inkWidth(_ text: String, font: NSFont) -> Double {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font]))
                return Double(CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
            }

            // Built from the journey's own extremes via the real formatting
            // functions, rather than duplicating their format strings here,
            // so this can't drift out of sync with what actually gets drawn.
            func extremes(_ values: [Double]) -> (min: Double, max: Double) {
                (values.min() ?? 0, values.max() ?? 0)
            }
            let (latMin, latMax) = extremes(records.map(\.latitude))
            let (lonMin, lonMax) = extremes(records.map(\.longitude))
            let feet = records.map(AltitudeRenderer.altitudeFeet(for:))

            let candidates = [
                AltitudeRenderer.latitudeText(latMin), AltitudeRenderer.latitudeText(latMax),
                AltitudeRenderer.longitudeText(lonMin), AltitudeRenderer.longitudeText(lonMax),
                AltitudeRenderer.altitudeText(feet: feet.min() ?? 0),
                AltitudeRenderer.altitudeText(feet: feet.max() ?? 0),
            ]

            let ceilingFont = NSFont.transport(size: AltitudeRenderer.fontSize)
            let widest = candidates.map { inkWidth($0, font: ceilingFont) }.max() ?? 0
            let availableWidth =
                AltitudeRenderer.boxWidth - 2 * AltitudeRenderer.textPadding

            // Ink width scales linearly with point size for an outline font,
            // so shrinking by the same ratio the widest candidate overflows
            // by is exact, not just an approximation.
            let fittedSize =
                widest > availableWidth && widest > 0
                ? AltitudeRenderer.fontSize * availableWidth / widest
                : AltitudeRenderer.fontSize
            font = NSFont.transport(size: max(AltitudeRenderer.minFontSize, fittedSize))
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

        // `artwork.font`'s point size was fitted in the abstract 120-unit
        // viewBox, same as every other measurement here, so it has to be
        // scaled up to the actual frame size like the box geometry is -
        // otherwise it draws at its literal (tiny) point size regardless of
        // `pixelSize`.
        let drawFont = NSFont.transport(size: artwork.font.pointSize * scale)
        for (index, text) in Self.rowTexts(for: record).enumerated() {
            drawRow(
                text, bottom: Self.rowBottom(index), scale: scale, font: drawFont,
                into: context)
        }
    }

    /// Matches the source SVG text conventions elsewhere: positioned by the
    /// glyphs' actual ink rather than the advance width and font metrics,
    /// since Transport's side bearings aren't symmetric and its glyphs don't
    /// sit where the metrics imply.
    private func drawRow(
        _ text: String, bottom: Double, scale: CGFloat, font: NSFont, into context: CGContext
    ) {
        let boxRect = CGRect(
            x: Self.boxLeft * scale, y: bottom * scale,
            width: Self.boxWidth * scale, height: Self.rowHeight * scale)

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
            "  \(concurrency)-way compositing, font size \(String(format: "%.1f", artwork.font.pointSize))pt",
        ]
    }
}
