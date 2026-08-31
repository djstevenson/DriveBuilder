import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the road-number intro badge: a green-and-white rounded-rectangle
/// frame (styled after a UK road sign) that fades in, then shows a
/// slot-machine spin of random real roads (number and title together)
/// before landing on the real road number and title, then fades out. Below
/// the badge, a fixed credit line fades in with it, but the title itself
/// stays blank until the spin starts. The area outside the frame stays
/// transparent.
struct IntroRenderer {
    static let dialName = "Intro"

    /// The road to land on, e.g. `roadType` "A" and `roadNumber` 3088 for
    /// "A3088", as recorded for the journey in the database.
    let roadType: String
    let roadNumber: Int

    /// The journey's title, as recorded in the database, shown below the badge.
    let title: String

    /// One road to show during the slot-machine spin: its number (e.g.
    /// "A4074") and a title in the same style as the real journey's (e.g.
    /// "Caversham to Littlemore").
    struct SpinEntry: Sendable {
        let roadText: String
        let title: String
    }

    /// Other real roads to cycle through during the spin, so the title
    /// animates in sync with the spinning number rather than sitting fixed
    /// on the real journey's title throughout. Empty falls back to the
    /// original random-digits-only spin with the real title held fixed.
    var spinEntries: [SpinEntry] = []

    /// Shown below the title, smaller and in a lighter colour.
    static let creditText = "A drive by Mekyrdo"

    var width = 840
    var height = 420
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
    /// scaled from this reference so the badge keeps its proportions. Taller
    /// than the badge alone needs (840x320), so there's room below it for
    /// the title and credit line.
    static let designWidth = 840.0
    static let designHeight = 420.0

    /// A 4K (UHD, 3840px-wide) screen's width; used to size the intro for
    /// near-full-screen display.
    static let uhd4KWidth = 3840.0

    /// Width and height for rendering at 80% of a 4K screen's width, with
    /// height scaled to preserve the badge's design aspect ratio.
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

    /// The badge rect from the SVG template, its 40px side margins matching
    /// exactly, and its original 30px top margin (from the SVG template's
    /// vertical centring, when the canvas was only as tall as the badge)
    /// preserved here at the top of the taller canvas above - the extra
    /// height all becomes room below the badge, for the title and credit
    /// line.
    static let designBadgeTopMargin = 30.0
    static let designBadgeRect = CGRect(
        x: 40, y: designHeight - designBadgeTopMargin - 260, width: 760, height: 260)
    static let designBadgeCornerRadius = 32.0

    private var badgeRect: CGRect {
        Self.designBadgeRect.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
    private var badgeCornerRadius: Double { Self.designBadgeCornerRadius * scale }

    /// The badge's outer green stroke extends `outerStrokeHalfWidth` beyond
    /// `badgeRect` itself, so this - not `badgeRect.minY` - is where the
    /// badge is actually visible down to.
    private var visibleBadgeBottom: Double { badgeRect.minY - outerStrokeHalfWidth }

    /// The strip below the visible badge, freed by shifting it up, split
    /// evenly between the title and the credit line.
    private var titleBandMinY: Double { visibleBadgeBottom / 2 }
    private var titleBandMaxY: Double { visibleBadgeBottom }
    private var creditBandMinY: Double { 0 }
    private var creditBandMaxY: Double { visibleBadgeBottom / 2 }

    static let designTitleFontSize = 32.0
    static let designCreditFontSize = 20.0
    private var titleFontSize: Double { Self.designTitleFontSize * scale }
    private var creditFontSize: Double { Self.designCreditFontSize * scale }

    static let titleColour = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let creditColour = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    /// Bold oblique Helvetica for the title, falling back to a synthesised
    /// bold-italic if that exact face isn't installed.
    private var titleFont: NSFont {
        NSFont(name: "Helvetica-BoldOblique", size: titleFontSize)
            ?? NSFontManager.shared.font(
                withFamily: "Helvetica", traits: [.boldFontMask, .italicFontMask], weight: 9,
                size: titleFontSize)
            ?? NSFont.boldSystemFont(ofSize: titleFontSize)
    }

    private var creditFont: NSFont {
        NSFont(name: "Helvetica", size: creditFontSize) ?? NSFont.systemFont(ofSize: creditFontSize)
    }

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
    private var font: NSFont { NSFont.boldSystemFont(ofSize: fontSize) }

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

    /// Precomputed once and reused across frames: the badge with just the
    /// fixed credit line and no title (used while fading in, and as the
    /// base for every spin frame, since the title there changes every
    /// frame), and the badge with the real title and road number both
    /// added on top (used unchanged for every reveal frame, and faded as a
    /// single image while fading out).
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
        drawTitle(title, into: revealedContext)
        drawText(roadText, into: revealedContext)
        guard let revealed = revealedContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let spinSequence = (0..<Self.spinFrames).compactMap { _ in spinEntries.randomElement() }

        return Artwork(blankBadge: blankBadge, revealed: revealed, spinSequence: spinSequence)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: the badge fading in, the spin,
    /// the reveal, then the whole badge and text fading out together.
    ///
    /// The spin's digits (and, when `artwork.spinSequence` isn't empty, its
    /// title) are drawn fresh for every frame, directly into `context` on
    /// top of the opaque badge, since full-opacity draws can be layered
    /// safely; the faded phases instead draw a single pre-flattened image,
    /// since fading badge and text separately at the same fractional alpha
    /// would double-blend where they overlap.
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
                // original random-digits spin, with no title (as when
                // fading in) until the real one appears at the reveal.
                context.draw(artwork.blankBadge, in: canvas)
                drawText(
                    Self.randomRoadText(roadType: roadType, digitCount: String(roadNumber).count),
                    into: context)
            } else {
                let entry = artwork.spinSequence[spinIndex % artwork.spinSequence.count]
                context.draw(artwork.blankBadge, in: canvas)
                drawText(entry.roadText, into: context)
                drawTitle(entry.title, into: context)
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

    /// Draws `string` in bold yellow, horizontally centred on the canvas and
    /// vertically centred on the badge (which may not be centred on the
    /// canvas itself, to leave room for the title below it).
    private func drawText(_ string: String, into context: CGContext) {
        drawCentredText(
            string, font: font, colour: Self.yellowColour,
            bandMinY: badgeRect.minY, bandMaxY: badgeRect.maxY, into: context)
    }

    /// Draws `text` in the upper half of the strip freed by shifting the
    /// badge up - the real title while fading in/reveal/fading out, or a
    /// spin entry's title while spinning.
    private func drawTitle(_ text: String, into context: CGContext) {
        drawCentredText(
            text, font: titleFont, colour: Self.titleColour,
            bandMinY: titleBandMinY, bandMaxY: titleBandMaxY, into: context)
    }

    /// Draws the fixed credit line in the lower half of that strip.
    private func drawCreditLine(into context: CGContext) {
        drawCentredText(
            Self.creditText, font: creditFont, colour: Self.creditColour,
            bandMinY: creditBandMinY, bandMaxY: creditBandMaxY, into: context)
    }

    /// Draws `string` in `font`/`colour`, horizontally centred on the
    /// canvas and vertically centred between `bandMinY` and `bandMaxY`.
    private func drawCentredText(
        _ string: String, font: NSFont, colour: CGColor, bandMinY: Double, bandMaxY: Double,
        into context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(cgColor: colour) ?? .white,
                ]))

        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        context.textPosition = CGPoint(
            x: Double(width) / 2 - (ink.minX + ink.width / 2),
            y: bandMinY + (bandMaxY - bandMinY - (ascent + descent)) / 2 + descent)
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
