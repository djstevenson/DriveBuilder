import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the road-number intro sign: a green-and-white rounded-rectangle
/// frame (styled after a UK road sign) that fades in, then shows a
/// slot-machine spin of random real roads (number and destinations
/// together) before landing on the real road number and destinations, then
/// fades out. Below the road number, on the sign itself, two left-aligned
/// destination lines (split from the journey's "X to Y" title) fade in with
/// the spin, and a fixed credit line sits below those. The whole sign is
/// centred both horizontally and vertically on the canvas; the area outside
/// it stays transparent.
struct IntroRenderer {
    static let dialName = "Intro"

    /// The road to land on, e.g. `roadType` "A" and `roadNumber` 3088 for
    /// "A3088", as recorded for the journey in the database.
    let roadType: String
    let roadNumber: Int

    /// The journey's title, as recorded in the database, e.g. "Caversham to
    /// Littlemore" - split on " to " into two left-aligned destination lines
    /// shown below the road number.
    let title: String

    /// One road to show during the slot-machine spin: its number (e.g.
    /// "A4074") and a title in the same style as the real journey's (e.g.
    /// "Caversham to Littlemore").
    struct SpinEntry: Sendable {
        let roadText: String
        let title: String
    }

    /// Other real roads to cycle through during the spin, so the
    /// destinations animate in sync with the spinning number rather than
    /// sitting fixed on the real journey's destinations throughout. Empty
    /// falls back to the original random-digits-only spin with the real
    /// destinations held fixed.
    var spinEntries: [SpinEntry] = []

    /// Shown below the destination lines, smaller, in the same white as the
    /// rest of the sign's text.
    static let creditText = "By Mekydro"

    var width = 840
    var height = 526
    var framesPerSecond: Int32 = 30

    static let fadeInFrames = 10
    static let spinFrames = 60
    static let revealFrames = 90
    static let fadeOutFrames = 10

    var frameCount: Int {
        Self.fadeInFrames + Self.spinFrames + Self.revealFrames + Self.fadeOutFrames
    }

    /// The canvas the layout below was designed at. `width`/`height` can be
    /// set to any size (e.g. to render nearly full-screen); everything is
    /// scaled from this reference so the sign keeps its proportions. Taller
    /// than the sign's own footprint by `designVerticalMargin` on each side,
    /// so the sign sits centred with breathing room around it.
    static let designWidth = 840.0
    static let designHeight =
        designBadgeHeight + 2 * designOuterStrokeHalfWidth + 2 * designVerticalMargin

    /// A 4K (UHD, 3840px-wide) screen's width; used to size the intro for
    /// near-full-screen display.
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

    /// `roadType` followed by `roadNumber`, e.g. "A" and `3088` -> "A3088".
    var roadText: String { "\(roadType)\(roadNumber)" }

    /// A random road-style number with the same digit count as `roadNumber`:
    /// first digit 1-9 (no leading zero), the rest 0-9.
    static func randomRoadText(roadType: String, digitCount: Int) -> String {
        var digits = String(Int.random(in: 1...9))
        for _ in 1..<digitCount {
            digits += String(Int.random(in: 0...9))
        }
        return roadType + digits
    }

    /// Splits a "X to Y" title into its two halves, e.g. "Caversham to
    /// Littlemore" -> ("Caversham", "Littlemore"). Titles that don't contain
    /// " to " (unexpected, but not fatal) come back as (title, "").
    static func splitTitle(_ title: String) -> (first: String, second: String) {
        guard let range = title.range(of: " to ") else { return (title, "") }
        return (String(title[..<range.lowerBound]), String(title[range.upperBound...]))
    }

    /// Precomputed once and reused across frames: the sign with just the
    /// fixed credit line and no road number or destinations (used while
    /// fading in, and as the base for every spin frame, since the number and
    /// destinations there change every frame), and the sign with the real
    /// road number and destinations both added on top (used unchanged for
    /// every reveal frame, and faded as a single image while fading out).
    struct Artwork {
        let blankBadge: CGImage
        let revealed: CGImage
        /// One entry per spin frame, picked from `spinEntries`; empty if
        /// none were supplied.
        let spinSequence: [SpinEntry]
    }

    func makeArtwork() throws -> Artwork {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        let blankBadgeContext = try LayerCompositor.bitmapContext(width: width, height: height)
        drawBadge(into: blankBadgeContext)
        drawCreditLine(into: blankBadgeContext)
        guard let blankBadge = blankBadgeContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let revealedContext = try LayerCompositor.bitmapContext(width: width, height: height)
        revealedContext.draw(blankBadge, in: canvas)
        drawDestinations(title, into: revealedContext)
        drawNumber(roadText, into: revealedContext)
        guard let revealed = revealedContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let spinSequence = (0..<Self.spinFrames).compactMap { _ in spinEntries.randomElement() }

        return Artwork(blankBadge: blankBadge, revealed: revealed, spinSequence: spinSequence)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: the sign fading in, the spin, the
    /// reveal, then the whole sign fading out.
    ///
    /// The spin's digits (and, when `artwork.spinSequence` isn't empty, its
    /// destinations) are drawn fresh for every frame, directly into
    /// `context` on top of the opaque sign, since full-opacity draws can be
    /// layered safely; the faded phases instead draw a single
    /// pre-flattened image, since fading the sign and text separately at
    /// the same fractional alpha would double-blend where they overlap.
    func draw(frameIndex: Int, into context: CGContext, artwork: Artwork) {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        if frameIndex < Self.fadeInFrames {
            let fraction = Double(frameIndex) / Double(Self.fadeInFrames - 1)
            context.setAlpha(fraction)
            context.draw(artwork.blankBadge, in: canvas)
            context.setAlpha(1)
        } else if frameIndex < Self.fadeInFrames + Self.spinFrames {
            let spinIndex = frameIndex - Self.fadeInFrames
            if artwork.spinSequence.isEmpty {
                // No real roads to cycle through - fall back to the
                // original random-digits spin, with no destinations (as
                // when fading in) until the real ones appear at the reveal.
                context.draw(artwork.blankBadge, in: canvas)
                drawNumber(
                    Self.randomRoadText(roadType: roadType, digitCount: String(roadNumber).count),
                    into: context)
            } else {
                let entry = artwork.spinSequence[spinIndex % artwork.spinSequence.count]
                context.draw(artwork.blankBadge, in: canvas)
                drawNumber(entry.roadText, into: context)
                drawDestinations(entry.title, into: context)
            }
        } else if frameIndex < Self.fadeInFrames + Self.spinFrames + Self.revealFrames {
            context.draw(artwork.revealed, in: canvas)
        } else {
            let fadeOutFrame = frameIndex - Self.fadeInFrames - Self.spinFrames - Self.revealFrames
            let fraction = 1 - Double(fadeOutFrame) / Double(Self.fadeOutFrames - 1)
            context.setAlpha(max(0, fraction))
            context.draw(artwork.revealed, in: canvas)
            context.setAlpha(1)
        }
    }

    /// The three nested rounded rects that reproduce the SVG template's
    /// two-stroke-plus-fill look: a green ring, a white ring inset from it,
    /// then the green fill on top, all filled rather than stroked so their
    /// edges land on exact pixel boundaries with no double-blended overlap.
    private func drawBadge(into context: CGContext) {
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
    private func drawNumber(_ string: String, into context: CGContext) {
        drawCentredText(
            string, font: font, colour: Self.yellowColour,
            bandMinY: numberBand.minY, bandMaxY: numberBand.maxY, into: context)
    }

    /// Splits `title` on " to " and draws the two halves as left-aligned
    /// white lines below the road number - the real destinations while
    /// fading in/reveal/fading out, or a spin entry's while spinning.
    private func drawDestinations(_ title: String, into context: CGContext) {
        let (first, second) = Self.splitTitle(title)
        drawLeftAlignedText(
            first, font: destinationFont, colour: Self.whiteColour,
            bandMinY: destinationLine1Band.minY, bandMaxY: destinationLine1Band.maxY,
            into: context)
        drawLeftAlignedText(
            second, font: destinationFont, colour: Self.whiteColour,
            bandMinY: destinationLine2Band.minY, bandMaxY: destinationLine2Band.maxY,
            into: context)
    }

    /// Draws the fixed credit line, left-aligned in white below the
    /// destination lines.
    private func drawCreditLine(into context: CGContext) {
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

    // MARK: - Movie

    /// One frame as a bitmap. For stills and tests, rather than the video path.
    func frame(at index: Int, artwork: Artwork) throws -> NSBitmapImageRep {
        let canvas = try SVGRasterizer.blankBitmap(width: width, height: height)
        try SVGRasterizer.withGraphicsContext(over: canvas) { context in
            draw(frameIndex: index, into: context.cgContext, artwork: artwork)
        }
        return canvas
    }

    func writeMovie(
        to url: URL,
        frameLimit: Int? = nil,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws {
        let artwork = try makeArtwork()
        let frameCount = min(frameCount, frameLimit ?? .max)

        print(
            String(
                format: "%@: \"%@\", %d frames at %dx%d %d fps.",
                Self.dialName, roadText, frameCount, width, height, framesPerSecond))

        var writer = AlphaMovieWriter(
            url: url, width: width, height: height, framesPerSecond: framesPerSecond)
        writer.concurrency = concurrency

        let started = ContinuousClock.now
        try await writer.write(
            frameCount: frameCount,
            drawFrame: { index, context in
                draw(frameIndex: index, into: context, artwork: artwork)
            })

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs to %@",
                Double(frameCount) / Double(framesPerSecond), width, height,
                seconds, url.path(percentEncoded: false)))
    }
}
