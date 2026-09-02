import AppKit
import CoreGraphics
import CoreText

/// The green-and-white UK-road-sign template shared by `IntroRenderer` and
/// `OutroRenderer`: the badge shape, its road-number/destination/credit text
/// bands, and the fonts and colours used to draw them. Kept in one place so
/// the outro's starting frame is pixel-for-pixel identical to the intro's
/// final one.
struct RoadSignArtwork {
    var width: Int
    var height: Int

    /// Shown below the destination lines, smaller, in the same white as the
    /// rest of the sign's text.
    static let creditText = "By Mekydro"

    /// The canvas the layout below was designed at. `width`/`height` can be
    /// set to any size (e.g. to render nearly full-screen); everything is
    /// scaled from this reference so the sign keeps its proportions. Taller
    /// than the sign's own footprint by `designVerticalMargin` on each side,
    /// so the sign sits centred with breathing room around it.
    static let designWidth = 840.0
    static let designHeight =
        designBadgeHeight + 2 * designOuterStrokeHalfWidth + 2 * designVerticalMargin

    /// A 4K (UHD, 3840px-wide) screen's width; used to size the intro and
    /// outro for near-full-screen display.
    static let uhd4KWidth = 3840.0

    /// Width and height for rendering at 80% of a 4K screen's width, with
    /// height scaled to preserve the sign's design aspect ratio.
    static var wideScreenSize: (width: Int, height: Int) {
        let width = Int((uhd4KWidth * 0.8).rounded())
        return (width: width, height: height(forWidth: width))
    }

    /// The height that preserves the design aspect ratio for a given width.
    static func height(forWidth width: Int) -> Int {
        Int((Double(width) * designHeight / designWidth).rounded())
    }

    /// How far the actual canvas is scaled up from the design canvas; every
    /// design-space measurement below is multiplied by this before drawing.
    private var scale: Double { Double(width) / Self.designWidth }

    /// Space kept clear around the visible sign (its outer stroke's edge),
    /// equal on every side, so it lands centred on the canvas.
    static let designVerticalMargin = 30.0
    static let designBadgeSideMargin = 40.0
    static let designBadgeCornerRadius = 32.0

    private var badgeRect: CGRect {
        let designRect = CGRect(
            x: Self.designBadgeSideMargin,
            y: (Self.designHeight - Self.designBadgeHeight) / 2,
            width: Self.designWidth - 2 * Self.designBadgeSideMargin,
            height: Self.designBadgeHeight)
        return designRect.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
    private var badgeCornerRadius: Double { Self.designBadgeCornerRadius * scale }

    /// Padding at the top and bottom of the sign's interior, around the
    /// road number and the destination/credit lines.
    static let designContentTopPadding = 20.0
    static let designContentBottomPadding = 20.0

    /// How far the destination and credit lines are indented from the
    /// sign's left edge.
    static let designContentLeftInset = 56.0

    /// Row heights and gaps that make up the sign's interior, stacked from
    /// the road number down to the credit line. Chosen generously enough
    /// that each font's ascent+descent (measured at the design font sizes)
    /// fits comfortably within its row.
    static let designNumberRowHeight = 260.0
    static let designGapAfterNumber = 16.0
    static let designDestinationLineHeight = 42.0
    static let designGapBeforeCredit = 8.0
    static let designCreditLineHeight = 28.0

    static let designBadgeHeight =
        designContentTopPadding + designNumberRowHeight + designGapAfterNumber
        + designDestinationLineHeight * 2 + designGapBeforeCredit + designCreditLineHeight
        + designContentBottomPadding

    private var contentTopPadding: Double { Self.designContentTopPadding * scale }
    private var contentLeftInset: Double { Self.designContentLeftInset * scale }
    private var numberRowHeight: Double { Self.designNumberRowHeight * scale }
    private var gapAfterNumber: Double { Self.designGapAfterNumber * scale }
    private var destinationLineHeight: Double { Self.designDestinationLineHeight * scale }
    private var gapBeforeCredit: Double { Self.designGapBeforeCredit * scale }
    private var creditLineHeight: Double { Self.designCreditLineHeight * scale }

    /// The road number's row, at the top of the sign's interior.
    private var numberBand: (minY: Double, maxY: Double) {
        let maxY = badgeRect.maxY - contentTopPadding
        return (maxY - numberRowHeight, maxY)
    }

    /// The first destination line's row, directly below the road number.
    private var destinationLine1Band: (minY: Double, maxY: Double) {
        let maxY = numberBand.minY - gapAfterNumber
        return (maxY - destinationLineHeight, maxY)
    }

    /// The second destination line's row, directly below the first.
    private var destinationLine2Band: (minY: Double, maxY: Double) {
        let maxY = destinationLine1Band.minY
        return (maxY - destinationLineHeight, maxY)
    }

    /// The credit line's row, at the bottom of the sign's interior.
    private var creditBand: (minY: Double, maxY: Double) {
        let maxY = destinationLine2Band.minY - gapBeforeCredit
        return (maxY - creditLineHeight, maxY)
    }

    static let designDestinationFontSize = 32.0
    static let designCreditFontSize = 20.0
    private var destinationFontSize: Double { Self.designDestinationFontSize * scale }
    private var creditFontSize: Double { Self.designCreditFontSize * scale }

    private var destinationFont: NSFont { NSFont.transport(size: destinationFontSize) }

    private var creditFont: NSFont { NSFont.transport(size: creditFontSize) }

    /// Half-widths of the template's two strokes (green 30, white 20), which
    /// is how far each extends outward from the badge rect's edge.
    static let designOuterStrokeHalfWidth = 15.0
    static let designMiddleStrokeHalfWidth = 10.0

    private var outerStrokeHalfWidth: Double { Self.designOuterStrokeHalfWidth * scale }
    private var middleStrokeHalfWidth: Double { Self.designMiddleStrokeHalfWidth * scale }

    static let greenColour = CGColor(srgbRed: 0, green: 0x80 / 255, blue: 0, alpha: 1)
    static let whiteColour = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let yellowColour = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    static let designFontSize = 200.0
    private var fontSize: Double { Self.designFontSize * scale }
    private var font: NSFont { NSFont.transport(size: fontSize) }

    /// The three nested rounded rects that reproduce the SVG template's
    /// two-stroke-plus-fill look: a green ring, a white ring inset from it,
    /// then the green fill on top, all filled rather than stroked so their
    /// edges land on exact pixel boundaries with no double-blended overlap.
    func drawBadge(into context: CGContext) {
        fillRoundedRect(inset: -outerStrokeHalfWidth, colour: Self.greenColour, into: context)
        fillRoundedRect(inset: -middleStrokeHalfWidth, colour: Self.whiteColour, into: context)
        fillRoundedRect(inset: 0, colour: Self.greenColour, into: context)
    }

    /// `badgeRect` grown outward by `-inset` (or shrunk if positive), with
    /// the corner radius adjusted by the same amount so the corners stay
    /// concentric.
    private func fillRoundedRect(inset: Double, colour: CGColor, into context: CGContext) {
        let rect = badgeRect.insetBy(dx: inset, dy: inset)
        let radius = badgeCornerRadius - inset
        let path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(colour)
        context.fillPath()
    }

    /// Draws `string` in bold yellow, horizontally centred on the sign and
    /// vertically centred in `numberBand`, at the top of the sign's
    /// interior.
    func drawNumber(_ string: String, into context: CGContext) {
        drawCentredText(
            string, font: font, colour: Self.yellowColour,
            bandMinY: numberBand.minY, bandMaxY: numberBand.maxY, into: context)
    }

    /// Splits `title` on " to " and draws the two halves as left-aligned
    /// white lines below the road number.
    func drawDestinations(_ title: String, into context: CGContext) {
        let (first, second) = RoadSignArtwork.splitTitle(title)
        drawLeftAlignedText(
            first, font: destinationFont, colour: Self.whiteColour,
            bandMinY: destinationLine1Band.minY, bandMaxY: destinationLine1Band.maxY,
            into: context)
        drawLeftAlignedText(
            second, font: destinationFont, colour: Self.whiteColour,
            bandMinY: destinationLine2Band.minY, bandMaxY: destinationLine2Band.maxY,
            into: context)
    }

    /// Splits a "X to Y" title into its two halves, e.g. "Caversham to
    /// Littlemore" -> ("Caversham", "Littlemore"). Titles that don't contain
    /// " to " (unexpected, but not fatal) come back as (title, "").
    static func splitTitle(_ title: String) -> (first: String, second: String) {
        guard let range = title.range(of: " to ") else { return (title, "") }
        return (String(title[..<range.lowerBound]), String(title[range.upperBound...]))
    }

    /// Draws the credit line, left-aligned in white below the destination
    /// lines.
    func drawCreditLine(into context: CGContext) {
        drawLeftAlignedText(
            Self.creditText, font: creditFont, colour: Self.whiteColour,
            bandMinY: creditBand.minY, bandMaxY: creditBand.maxY, into: context)
    }

    /// Draws `string` in `font`/`colour`, horizontally centred on the sign
    /// and vertically centred between `bandMinY` and `bandMaxY`.
    private func drawCentredText(
        _ string: String, font: NSFont, colour: CGColor, bandMinY: Double, bandMaxY: Double,
        into context: CGContext
    ) {
        let line = makeLine(string, font: font, colour: colour)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        drawLine(
            line, ink: ink, x: Double(width) / 2 - (ink.minX + ink.width / 2),
            bandMinY: bandMinY, bandMaxY: bandMaxY, into: context)
    }

    /// Draws `string` in `font`/`colour`, left-aligned at `contentLeftInset`
    /// from the sign's left edge and vertically centred between `bandMinY`
    /// and `bandMaxY`.
    private func drawLeftAlignedText(
        _ string: String, font: NSFont, colour: CGColor, bandMinY: Double, bandMaxY: Double,
        into context: CGContext
    ) {
        let line = makeLine(string, font: font, colour: colour)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        drawLine(
            line, ink: ink, x: badgeRect.minX + contentLeftInset,
            bandMinY: bandMinY, bandMaxY: bandMaxY, into: context)
    }

    private func makeLine(_ string: String, font: NSFont, colour: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(cgColor: colour) ?? .white,
                ]))
    }

    /// Positions `line` so its actual glyph ink - rather than the font's
    /// ascent/descent metrics, which for some fonts (e.g. Transport) don't
    /// match where the glyphs are actually drawn - sits vertically centred
    /// between `bandMinY` and `bandMaxY`.
    private func drawLine(
        _ line: CTLine, ink: CGRect, x: Double, bandMinY: Double, bandMaxY: Double,
        into context: CGContext
    ) {
        context.textPosition = CGPoint(
            x: x, y: bandMinY + (bandMaxY - bandMinY - ink.height) / 2 - ink.minY)
        CTLineDraw(line, context)
    }
}
