import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds one annotation banner: two green lines rise together from below
/// the frame's bottom edge, the lower one stopping just above it while the
/// upper one continues to the top of the band, revealing a black band
/// between them; text scrolls across right to left, and the whole thing
/// reverses back down once the text has fully scrolled off. Everything
/// outside the band is transparent.
///
/// A port of the Perl pipeline's `DriveBuilder::Video::Annotation`, with the
/// text colour changed from white to yellow and the open/close animation
/// re-anchored to rise from the bottom edge (the Perl opened from the
/// centre).
struct AnnotationRenderer {
    static let dialName = "Annotation"

    let text: String

    var width = 3840

    /// Height of the fully open band, including both boundary lines.
    var bandHeight = 160

    /// Transparent rows kept below the band: the resting gap between the
    /// anchored bottom line and the video's bottom edge, which the lines
    /// rise through on their way in. The final composition places the clip
    /// flush with the video's bottom edge, so the clip's own bottom row is
    /// the video's.
    static let bottomInset = 10

    /// The movie frame height: the band plus the inset it rises through.
    var height: Int { bandHeight + Self.bottomInset }

    var framesPerSecond: Int32 = 30

    /// Seconds for the lines to open before, and close after, the scroll.
    static let openSeconds = 0.7
    static let closeSeconds = 0.7

    /// How fast the text scrolls, in pixels per second.
    static let scrollSpeed = 540.0

    /// Thickness of each green boundary line: 4 rows at 4K, so the lines
    /// survive as a clear 1 px when the video is watched at 1080p.
    static let lineHeight = 4

    /// Horizontal padding either side of the text's ink.
    static let textPadding = 24.0

    static let fontSize = 92.0

    static let borderColour = CGColor(
        srgbRed: 0x66 / 255, green: 0x99 / 255, blue: 0x33 / 255, alpha: 1)
    static let backgroundColour = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let textColour = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    static var font: NSFont { NSFont.transport(size: fontSize) }

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

        let context = try LayerCompositor.bitmapContext(width: textWidth, height: bandHeight)

        // Centre the glyphs' actual ink vertically in the band, rather
        // than the font's ascent/descent metrics - for some fonts (e.g.
        // Transport) those don't match where the glyphs are actually drawn.
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let baselineY = (Double(bandHeight) - ink.height) / 2 - ink.minY

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

    /// The banner `progress` of the way open. Both lines rise together at
    /// one constant speed from just below the frame's bottom edge (0): the
    /// bottom line stops when it reaches its resting row above the inset,
    /// while the top line carries on to the top of the band (1), with black
    /// filling the gap once they separate. Closing runs the same path in
    /// reverse: the top line descends, collects the bottom line, and both
    /// sink back off the bottom edge.
    ///
    /// Positions are integer pixels: at 30 fps the lines move several pixels
    /// per frame anyway, and integer boundaries avoid partially transparent
    /// antialiased rows at the edge of the alpha banner.
    private func drawBanner(progress: Double, into context: CGContext) {
        let progress = min(1, max(0, progress))
        let lineHeight = Self.lineHeight

        // Top-left-origin rows. At progress 0 the top line's first row is
        // `height` — one past the canvas's last row, so entirely below the
        // video's bottom edge and invisible.
        let topLineY = Int((Double(height) * (1 - progress)).rounded())
        let bottomLineRest = height - Self.bottomInset - lineHeight
        let bottomLineY = max(topLineY, bottomLineRest)

        // Black appears only between the two green lines.
        let blackY = topLineY + lineHeight
        let blackHeight = bottomLineY - blackY
        if blackHeight > 0 {
            context.setFillColor(Self.backgroundColour)
            context.fill(rect(top: blackY, height: blackHeight))
        }

        context.setFillColor(Self.borderColour)
        context.fill(rect(top: topLineY, height: lineHeight))
        // While the lines rise together they occupy the same pixels, so the
        // second rectangle is harmless and keeps opening and closing
        // symmetrical.
        context.fill(rect(top: bottomLineY, height: lineHeight))
    }

    /// The cached text image at horizontal offset `x`, clipped so the scroll
    /// never paints over the green boundary lines.
    private func drawText(_ artwork: Artwork, x: Double, into context: CGContext) {
        context.saveGState()
        // The band's interior: between the top line and the bottom line's
        // resting position, both `lineHeight` tall.
        context.clip(
            to: rect(top: Self.lineHeight, height: bandHeight - 2 * Self.lineHeight))
        context.draw(
            artwork.textImage,
            in: CGRect(
                x: x, y: Double(Self.bottomInset),
                width: Double(artwork.textWidth), height: Double(bandHeight)))
        context.restoreGState()
    }

    /// A full-width band `rowCount` rows tall whose top edge is `top` rows
    /// below the banner's top, converted to the context's bottom-left origin.
    private func rect(top: Int, height rowCount: Int) -> CGRect {
        CGRect(x: 0, y: height - top - rowCount, width: width, height: rowCount)
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
