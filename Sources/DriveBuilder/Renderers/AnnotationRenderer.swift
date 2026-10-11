import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds one annotation banner: a translucent dark band widens leftwards
/// out of its right edge, text scrolls across it right to left, and once
/// the text has fully scrolled off the band's right edge sweeps leftwards
/// too, collapsing it into its left edge - so every movement runs right to
/// left. Everything outside the band is transparent.
///
/// The movie is exactly the fully open band, which the final composition
/// places in the bottom-left corner, flush with the main footage's left
/// edge and `rightMargin` short of the dial column, as if on the column's
/// grid.
///
/// A port of the Perl pipeline's `DriveBuilder::Video::Annotation`, with the
/// text colour changed from white to yellow, the green boundary lines
/// dropped, the background made translucent to match the telemetry dials,
/// and the banner opening sideways rather than vertically.
struct AnnotationRenderer {
    static let dialName = "Annotation"

    let text: String

    /// The dial column's grid gap: the band's distance from the dial column.
    static let rightMargin = TelemetryVideoRenderer.defaultGap

    /// Width of the fully open band, which is also the movie frame width:
    /// the 3840 px final frame less the dial column and the margin before it.
    var width = 3840 - TelemetryVideoRenderer.defaultMapPixelSize - rightMargin

    /// Height of the band, which is also the movie frame height.
    var height = 160

    var framesPerSecond: Int32 = 30

    /// Seconds for the band to open before, and close after, the scroll.
    static let openSeconds = 0.7
    static let closeSeconds = 0.7

    /// How fast the text scrolls, in pixels per second.
    static let scrollSpeed = 540.0

    /// Horizontal padding either side of the text's ink.
    static let textPadding = 24.0

    static let fontSize = 92.0

    /// Matches the telemetry dials' background, so a hint of the main video
    /// shows through the band.
    static let backgroundColour = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
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

    /// One extra frame is intentional: after the band closes at the end, it
    /// gives a fully transparent frame before the movie ends.
    var frameCount: Int {
        let duration = Self.openSeconds + scrollSeconds + Self.closeSeconds
        return Int((duration * Double(framesPerSecond)).rounded(.up)) + 1
    }

    // MARK: - Artwork

    func makeArtwork() throws -> Artwork {
        let line = textLine
        let textWidth = Self.textWidth(of: line)

        let context = try LayerCompositor.bitmapContext(width: textWidth, height: height)

        // Centre the glyphs' actual ink vertically in the band, rather
        // than the font's ascent/descent metrics - for some fonts (e.g.
        // Transport) those don't match where the glyphs are actually drawn.
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let baselineY = (Double(height) - ink.height) / 2 - ink.minY

        context.textPosition = CGPoint(
            x: Self.textPadding - min(ink.minX, 0), y: baselineY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return Artwork(textImage: image, textWidth: textWidth)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: opening band, then the scroll
    /// with the band fully open, then closing band, then one fully
    /// transparent frame.
    func draw(frameIndex: Int, into context: CGContext, artwork: Artwork) {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let t = Double(frameIndex) / Double(framesPerSecond)
        let scrollSeconds = Double(width + artwork.textWidth) / Self.scrollSpeed

        if t < Self.openSeconds {
            // The left edge sweeps in from the right.
            let left = width - column(at: t / Self.openSeconds)
            drawBand(from: left, to: width, into: context)
        } else if t < Self.openSeconds + scrollSeconds {
            drawBand(from: 0, to: width, into: context)
            let x = Double(width) - (t - Self.openSeconds) * Self.scrollSpeed
            context.draw(
                artwork.textImage,
                in: CGRect(
                    x: x, y: 0, width: Double(artwork.textWidth), height: Double(height)))
        } else if t < Self.openSeconds + scrollSeconds + Self.closeSeconds {
            // The right edge follows it out to the left.
            let closeT = t - Self.openSeconds - scrollSeconds
            let right = width - column(at: closeT / Self.closeSeconds)
            drawBand(from: 0, to: right, into: context)
        }
        // else: leave the final frame completely transparent.
    }

    /// How far a moving edge has travelled, in whole columns, `progress`
    /// (clamped to 0...1) of the way across the frame at constant speed.
    ///
    /// The edges are integer columns: at 30 fps they move many pixels per
    /// frame anyway, and integer boundaries avoid partially transparent
    /// antialiased columns at the edges of the alpha banner.
    private func column(at progress: Double) -> Int {
        Int((Double(width) * min(1, max(0, progress))).rounded())
    }

    /// The band, full height, across columns `left..<right`.
    private func drawBand(from left: Int, to right: Int, into context: CGContext) {
        guard right > left else { return }
        context.setFillColor(Self.backgroundColour)
        context.fill(CGRect(x: left, y: 0, width: right - left, height: height))
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
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        progress: RenderProgressHandler? = nil
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
            progress: { done in
                progress?(.fraction(Double(done) / Double(max(frameCount, 1))))
            },
            drawFrame: { index, context in
                draw(frameIndex: index, into: context, artwork: artwork)
            })

        let elapsed = started.duration(to: .now)
        let seconds = elapsed / .seconds(1)
        print(
            String(
                format: "  wrote %.1fs of %dx%d ProRes 4444 in %.1fs to %@",
                Double(frameCount) / Double(framesPerSecond), width, height,
                seconds, url.path(percentEncoded: false)))
    }
}
