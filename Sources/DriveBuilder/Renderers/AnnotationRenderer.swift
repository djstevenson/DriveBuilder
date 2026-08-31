import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds one annotation banner: two green lines that open up from the centre
/// to reveal a black band, text scrolling across it right to left, and the
/// lines closing again once the text has fully scrolled off. Everything
/// outside the band is transparent.
///
/// A port of the Perl pipeline's `DriveBuilder::Video::Annotation`, with the
/// text colour changed from white to yellow.
struct AnnotationRenderer {
    static let dialName = "Annotation"

    let text: String

    var width = 3840
    var height = 80
    var framesPerSecond: Int32 = 30

    /// Seconds for the lines to open before, and close after, the scroll.
    static let openSeconds = 0.7
    static let closeSeconds = 0.7

    /// How fast the text scrolls, in pixels per second.
    static let scrollSpeed = 300.0

    /// Thickness of each green boundary line.
    static let lineHeight = 2

    /// Horizontal padding either side of the text's ink.
    static let textPadding = 24.0

    static let fontSize = 42.0

    static let borderColour = CGColor(
        srgbRed: 0x66 / 255, green: 0x99 / 255, blue: 0x33 / 255, alpha: 1)
    static let backgroundColour = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let textColour = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    /// The Perl rendered with Cairo's bold Helvetica; fall back to the system
    /// bold face if it's ever unavailable rather than failing the render.
    static var font: NSFont {
        NSFont(name: "Helvetica-Bold", size: fontSize)
            ?? NSFont.boldSystemFont(ofSize: fontSize)
    }

    /// The text rendered once; every frame composites it at a different x.
    struct Artwork {
        let textImage: CGImage
        let textWidth: Int
    }

    // MARK: - Frame plan

    /// The text's rendered width: ink and advance extents (whichever reaches
    /// further, so overhanging glyphs aren't clipped) plus the padding.
    static func textWidth(of line: CTLine) -> Int {
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let left = min(ink.minX, 0)
        let right = max(advance, ink.maxX)
        return Int(((right - left) + 2 * textPadding).rounded(.up))
    }

    var textLine: CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: NSColor(cgColor: Self.textColour) ?? .yellow,
                ]))
    }

    /// Seconds for the text to enter at the right edge and leave at the left.
    var scrollSeconds: Double {
        Double(width + Self.textWidth(of: textLine)) / Self.scrollSpeed
    }

    /// One extra frame is intentional: after the two green lines meet at the
    /// end, it gives a fully transparent frame before the movie ends.
    var frameCount: Int {
        let duration = Self.openSeconds + scrollSeconds + Self.closeSeconds
        return Int((duration * Double(framesPerSecond)).rounded(.up)) + 1
    }

    // MARK: - Artwork

    func makeArtwork() throws -> Artwork {
        let line = textLine
        let textWidth = Self.textWidth(of: line)

        let context = try LayerCompositor.bitmapContext(width: textWidth, height: height)

        // Centre the font's ascent+descent box vertically in the banner.
        // The context has a bottom-left origin, so the baseline sits its
        // descent-plus-margin above the bottom edge.
        let ascent = CTFontGetAscent(Self.font)
        let descent = CTFontGetDescent(Self.font)
        let baselineY = (Double(height) - (ascent + descent)) / 2 + descent

        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.textPosition = CGPoint(
            x: Self.textPadding - min(ink.minX, 0), y: baselineY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return Artwork(textImage: image, textWidth: textWidth)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: opening lines, then the scroll
    /// with the banner fully open, then closing lines, then one fully
    /// transparent frame.
    func draw(frameIndex: Int, into context: CGContext, artwork: Artwork) {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let t = Double(frameIndex) / Double(framesPerSecond)
        let scrollSeconds = Double(width + artwork.textWidth) / Self.scrollSpeed

        if t < Self.openSeconds {
            drawBanner(progress: t / Self.openSeconds, into: context)
        } else if t < Self.openSeconds + scrollSeconds {
            drawBanner(progress: 1, into: context)
            let x = Double(width) - (t - Self.openSeconds) * Self.scrollSpeed
            drawText(artwork, x: x, into: context)
        } else if t < Self.openSeconds + scrollSeconds + Self.closeSeconds {
            let closeT = t - Self.openSeconds - scrollSeconds
            drawBanner(progress: max(0, 1 - closeT / Self.closeSeconds), into: context)
        }
        // else: leave the final frame completely transparent.
    }

    /// The two green lines `progress` of the way from meeting at the centre
    /// (0) to the banner's edges (1), with black filling the gap between them.
    ///
    /// Positions are integer pixels: at 30 fps the lines move roughly two
    /// pixels per frame anyway, and integer boundaries avoid partially
    /// transparent antialiased rows at the edge of the alpha banner.
    private func drawBanner(progress: Double, into context: CGContext) {
        let progress = min(1, max(0, progress))
        let lineHeight = Self.lineHeight

        let centre = Double(height) / 2
        let halfTravel = Double(height - lineHeight) / 2

        // Top-left-origin rows, as the Perl computes them.
        let topLineY = Int((centre - Double(lineHeight) / 2 - halfTravel * progress).rounded())
        let bottomLineY = Int((centre - Double(lineHeight) / 2 + halfTravel * progress).rounded())

        // Black appears only between the two green lines.
        let blackY = topLineY + lineHeight
        let blackHeight = bottomLineY - blackY
        if blackHeight > 0 {
            context.setFillColor(Self.backgroundColour)
            context.fill(rect(top: blackY, height: blackHeight))
        }

        context.setFillColor(Self.borderColour)
        context.fill(rect(top: topLineY, height: lineHeight))
        // At progress == 0 both lines occupy the same pixels, so the second
        // rectangle is harmless and keeps opening and closing symmetrical.
        context.fill(rect(top: bottomLineY, height: lineHeight))
    }

    /// The cached text image at horizontal offset `x`, clipped so the scroll
    /// never paints over the green boundary lines.
    private func drawText(_ artwork: Artwork, x: Double, into context: CGContext) {
        context.saveGState()
        context.clip(
            to: rect(top: Self.lineHeight, height: height - 2 * Self.lineHeight))
        context.draw(
            artwork.textImage,
            in: CGRect(x: x, y: 0, width: Double(artwork.textWidth), height: Double(height)))
        context.restoreGState()
    }

    /// A full-width band `height` rows tall whose top edge is `top` rows below
    /// the banner's top, converted to the context's bottom-left origin.
    private func rect(top: Int, height bandHeight: Int) -> CGRect {
        CGRect(x: 0, y: height - top - bandHeight, width: width, height: bandHeight)
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
                Self.dialName, text, frameCount, width, height, framesPerSecond))

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
