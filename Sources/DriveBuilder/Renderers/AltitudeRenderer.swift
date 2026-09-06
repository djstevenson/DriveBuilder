import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the altitude indicator for a journey: latitude, longitude,
/// altitude, and odometer as text, each on its own opaque box so the numbers
/// stay legible whatever the dashcam footage behind the dial is doing.
///
/// Takes the telemetry it needs as a plain array so it can be exercised with
/// synthetic records, without a database.
struct AltitudeRenderer: DialRenderer {
    static let dialName = "Altitude"

    /// Telemetry `altitude` is metres; the indicator reads in feet.
    static let feetPerMetre = 3.280839895

    /// Telemetry `odometer` is metres; the indicator reads in miles, since
    /// that's what UK road distances are signed in.
    static let metresPerMile = 1609.344

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 345

    /// Colour and opacity of the square backdrop drawn behind the dial,
    /// matching the speedo, g-force, and compass dials.
    static let backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    /// Fully opaque, unlike the square backdrop above: the box is what
    /// actually keeps the text readable, so it can't let footage show
    /// through the way the dimmed backdrop does.
    static let boxColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Upper limit on the font size: a full 4-decimal "LON -179.9999" doesn't
    /// fit a fixed-width box at this size, so `Artwork` shrinks it just
    /// enough for the journey's actual extremes to fit rather than using it
    /// outright.
    static let fontSize = 26.0
    static let minFontSize = 10.0
    static let cornerRadius = 4.0

    /// Applied after fitting the widest value to the box width, so the text
    /// sits at 60% of that width instead of filling it edge to edge - this
    /// leaves margin above and below too, since the glyphs are smaller
    /// relative to the fixed row height.
    static let textScale = 0.6

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
    static let rowGap = 3.0
    static let topMargin = 5.0

    /// The row that gets a mountain icon instead of a text label: altitude,
    /// third from the top.
    static let altitudeRowIndex = 2

    /// A simplified two-peak mountain silhouette, normalised to a unit
    /// square (0,0)-(1,1) with its base on the x-axis - a smaller redraw of
    /// the profile in the mountain SVG this dial used to show at full size.
    private static let mountainProfile: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.2778, y: 0.6667),
        CGPoint(x: 0.5, y: 0.3333),
        CGPoint(x: 0.7222, y: 1.0),
        CGPoint(x: 1, y: 0),
    ]

    /// Icon height as a fraction of the font's point size, so it scales
    /// with the text instead of needing its own fitted size.
    private static let mountainIconHeightRatio = 0.75
    /// Width:height of the original mountain artwork (90:60 in its 120-unit
    /// viewBox).
    private static let mountainIconAspect = 1.5
    /// Gap between the icon and the text, also relative to font size so the
    /// whole leading section scales linearly with it (see `Artwork.init`).
    private static let mountainIconGapRatio = 0.3
    /// Combined width of the icon and its trailing gap, as a multiple of
    /// font point size.
    private static let mountainLeadingRatio =
        mountainIconHeightRatio * mountainIconAspect + mountainIconGapRatio

    /// The mountain silhouette scaled and positioned to fill `rect`.
    private static func mountainPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let points = mountainProfile.map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

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

    /// No "ALT" label either, for the same reason - a small mountain icon
    /// marks the row instead (see `mountainPath(in:)`).
    static func altitudeText(feet: Int) -> String {
        "\(feet) ft"
    }

    /// Car odometers read to a tenth of a mile, so this matches that
    /// resolution rather than implying more precision than the GPS-derived
    /// distance actually has.
    static func odometerText(miles: Double) -> String {
        String(format: "%.1f mi", miles)
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

    static func odometerText(_ record: TelemetryRecord) -> String {
        odometerText(miles: record.odometer / metresPerMile)
    }

    /// The four rows drawn for a record, top to bottom.
    static func rowTexts(for record: TelemetryRecord) -> [String] {
        [
            latitudeText(record), longitudeText(record), altitudeText(record),
            odometerText(record),
        ]
    }

    /// A row's bottom edge, in the nominal 120-unit viewBox the other dials'
    /// artwork uses, counted down from the top.
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
            let (milesMin, milesMax) = extremes(
                records.map { $0.odometer / AltitudeRenderer.metresPerMile })

            let candidates = [
                AltitudeRenderer.latitudeText(latMin), AltitudeRenderer.latitudeText(latMax),
                AltitudeRenderer.longitudeText(lonMin), AltitudeRenderer.longitudeText(lonMax),
                AltitudeRenderer.odometerText(miles: milesMin),
                AltitudeRenderer.odometerText(miles: milesMax),
            ]
            // The altitude row spends some of its width on the mountain
            // icon instead of text, so its candidates need that allowance
            // added - both scale with font size, so the ratio stays exact.
            let altitudeCandidates = [
                AltitudeRenderer.altitudeText(feet: feet.min() ?? 0),
                AltitudeRenderer.altitudeText(feet: feet.max() ?? 0),
            ]

            let ceilingFont = NSFont.transport(size: AltitudeRenderer.fontSize)
            let mountainLeadingWidth =
                AltitudeRenderer.fontSize * AltitudeRenderer.mountainLeadingRatio
            let widest =
                (candidates.map { inkWidth($0, font: ceilingFont) }
                    + altitudeCandidates.map { inkWidth($0, font: ceilingFont) + mountainLeadingWidth })
                .max() ?? 0
            let availableWidth =
                AltitudeRenderer.boxWidth - 2 * AltitudeRenderer.textPadding

            // Ink width scales linearly with point size for an outline font,
            // so shrinking by the same ratio the widest candidate overflows
            // by is exact, not just an approximation.
            let fittedSize =
                widest > availableWidth && widest > 0
                ? AltitudeRenderer.fontSize * availableWidth / widest
                : AltitudeRenderer.fontSize
            font = NSFont.transport(
                size: max(AltitudeRenderer.minFontSize, fittedSize * AltitudeRenderer.textScale))
        }
    }

    func makeArtwork() throws -> Artwork {
        Artwork(records: records)
    }

    /// Draws one frame into `context`: three opaque rounded boxes, one per
    /// line of text.
    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: Artwork) {
        let scale = CGFloat(pixelSize) / 120
        let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        context.clear(bounds)
        context.setFillColor(Self.backgroundColor)
        context.fill(bounds)

        // `artwork.font`'s point size was fitted in the abstract 120-unit
        // viewBox, same as every other measurement here, so it has to be
        // scaled up to the actual frame size like the box geometry is -
        // otherwise it draws at its literal (tiny) point size regardless of
        // `pixelSize`.
        let drawFont = NSFont.transport(size: artwork.font.pointSize * scale)
        for (index, text) in Self.rowTexts(for: record).enumerated() {
            drawRow(
                text, bottom: Self.rowBottom(index), scale: scale, font: drawFont,
                showsMountainIcon: index == Self.altitudeRowIndex, into: context)
        }
    }

    /// Matches the source SVG text conventions elsewhere: positioned by the
    /// glyphs' actual ink rather than the advance width and font metrics,
    /// since Transport's side bearings aren't symmetric and its glyphs don't
    /// sit where the metrics imply.
    private func drawRow(
        _ text: String, bottom: Double, scale: CGFloat, font: NSFont, showsMountainIcon: Bool,
        into context: CGContext
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

        var textLeft = boxRect.minX + Self.textPadding * scale
        if showsMountainIcon {
            let iconHeight = font.pointSize * Self.mountainIconHeightRatio
            let iconWidth = iconHeight * Self.mountainIconAspect
            let iconRect = CGRect(
                x: textLeft, y: boxRect.minY + (boxRect.height - iconHeight) / 2,
                width: iconWidth, height: iconHeight)
            context.setFillColor(Self.textColor)
            context.addPath(Self.mountainPath(in: iconRect))
            context.fillPath()
            textLeft += iconWidth + font.pointSize * Self.mountainIconGapRatio
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

        context.setFillColor(Self.textColor)
        context.textPosition = CGPoint(
            x: textLeft - ink.minX,
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
