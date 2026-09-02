import AppKit
import CoreGraphics
import Foundation

/// Builds the road-number outro sign: the reverse of `IntroRenderer`'s
/// ending. Starts already showing the same revealed sign `IntroRenderer`
/// ends on - real road number, real destinations, and the credit line, all
/// fully opaque, so the two clips can cross-fade into one another - then
/// holds for a few seconds before the road number and both destination
/// lines cross-fade to "Bye...", "Thanks for", and "Watching". The credit
/// line then fades out on its own, and the sign holds like that (no credit,
/// the sign-off text in place) for the rest of the clip.
///
/// The badge's shape, bands, fonts, and colours live in `RoadSignArtwork`,
/// shared with `IntroRenderer` so this starting frame matches that one's
/// final frame exactly.
struct OutroRenderer {
    static let dialName = "Outro"

    /// The road the intro ended on, e.g. `roadType` "A" and `roadNumber`
    /// 3088 for "A3088", as recorded for the journey in the database.
    let roadType: String
    let roadNumber: Int

    /// The journey's title, as recorded in the database, e.g. "Caversham to
    /// Littlemore" - split on " to " into the same two destination lines
    /// shown by the intro, before they change to the sign-off text.
    let title: String

    static let signOffNumberText = "Bye..."
    static let signOffFirstLine = "Thanks for"
    static let signOffSecondLine = "Watching"

    var width = 840
    var height = 526
    var framesPerSecond: Int32 = 30

    /// How long the sign holds showing the real road, destinations, and
    /// credit line before the sign-off text starts appearing.
    static let initialHoldFrames = 90
    /// How long the road number and destination lines take to cross-fade
    /// from the real journey's text to the sign-off text.
    static let textChangeFrames = 20
    /// How long the credit line takes to fade out once the sign-off text is
    /// showing.
    static let creditFadeOutFrames = 15
    /// How long the sign holds on the sign-off text with no credit line,
    /// at the end of the clip.
    static let finalHoldFrames = 90

    var frameCount: Int {
        Self.initialHoldFrames + Self.textChangeFrames + Self.creditFadeOutFrames
            + Self.finalHoldFrames
    }

    private var sign: RoadSignArtwork { RoadSignArtwork(width: width, height: height) }

    /// `roadType` followed by `roadNumber`, e.g. "A" and `3088` -> "A3088".
    var roadText: String { "\(roadType)\(roadNumber)" }

    /// Precomputed once and reused across frames: the badge with the real
    /// road number and destinations (as `IntroRenderer` ends on), and the
    /// badge with the sign-off text instead - both without the credit line,
    /// which every frame draws separately on top so it can fade out on its
    /// own.
    struct Artwork {
        let original: CGImage
        let signOff: CGImage
    }

    func makeArtwork() throws -> Artwork {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        let badgeContext = try LayerCompositor.bitmapContext(width: width, height: height)
        sign.drawBadge(into: badgeContext)
        guard let badge = badgeContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let originalContext = try LayerCompositor.bitmapContext(width: width, height: height)
        originalContext.draw(badge, in: canvas)
        sign.drawDestinations(title, into: originalContext)
        sign.drawNumber(roadText, into: originalContext)
        guard let original = originalContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let signOffContext = try LayerCompositor.bitmapContext(width: width, height: height)
        signOffContext.draw(badge, in: canvas)
        sign.drawDestinations("\(Self.signOffFirstLine) to \(Self.signOffSecondLine)", into: signOffContext)
        sign.drawNumber(Self.signOffNumberText, into: signOffContext)
        guard let signOff = signOffContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        return Artwork(original: original, signOff: signOff)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: the real reveal held, then
    /// cross-fading to the sign-off text, then the credit line fading out,
    /// then a final hold.
    ///
    /// The road number and destinations cross-fade by drawing both fully
    /// opaque images on top of one another at complementary alpha, the same
    /// safe way `IntroRenderer` fades its whole sign in - rather than
    /// fading the old and new text separately, which would double-blend
    /// where they overlap. The credit line, drawn fresh every frame on top,
    /// never overlaps that text, so it can fade directly.
    func draw(frameIndex: Int, into context: CGContext, artwork: Artwork) {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        let textChangeStart = Self.initialHoldFrames
        let textChangeEnd = textChangeStart + Self.textChangeFrames
        let creditFadeEnd = textChangeEnd + Self.creditFadeOutFrames

        if frameIndex < textChangeStart {
            context.draw(artwork.original, in: canvas)
            sign.drawCreditLine(into: context)
        } else if frameIndex < textChangeEnd {
            let fraction =
                Double(frameIndex - textChangeStart) / Double(Self.textChangeFrames - 1)
            context.draw(artwork.original, in: canvas)
            context.setAlpha(fraction)
            context.draw(artwork.signOff, in: canvas)
            context.setAlpha(1)
            sign.drawCreditLine(into: context)
        } else if frameIndex < creditFadeEnd {
            let fraction =
                1 - Double(frameIndex - textChangeEnd) / Double(Self.creditFadeOutFrames - 1)
            context.draw(artwork.signOff, in: canvas)
            context.setAlpha(max(0, fraction))
            sign.drawCreditLine(into: context)
            context.setAlpha(1)
        } else {
            context.draw(artwork.signOff, in: canvas)
        }
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
