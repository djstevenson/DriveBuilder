import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Builds the road-number intro sign: a green-and-white rounded-rectangle
/// frame (styled after a UK road sign) that fades in, then shows a
/// slot-machine spin of random real roads (number and destinations
/// together) before landing on the real road number and destinations,
/// then holding there (no fade-out, so it can cross-fade into the next
/// clip). Below the road number, on the sign itself, two left-aligned
/// destination lines (split from the journey's "X to Y" title) fade in with
/// the spin, and a credit line fades in below those a little after the
/// final road is revealed. The whole sign is centred both horizontally and
/// vertically on the canvas; the area outside it stays transparent.
///
/// The badge's shape, bands, fonts, and colours live in `RoadSignArtwork`,
/// shared with `OutroRenderer` so the outro's starting frame matches this
/// one's final frame exactly.
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

    var width = 840
    var height = 526
    var framesPerSecond: Int32 = 30

    static let fadeInFrames = 10
    static let spinFrames = 60
    static let revealFrames = 90

    /// How far into the reveal the credit line waits before it starts
    /// fading in, so it appears once the final road has had a moment to
    /// register, and how long that fade takes.
    static let creditFadeInDelayFrames = 20
    static let creditFadeInFrames = 15

    var frameCount: Int {
        Self.fadeInFrames + Self.spinFrames + Self.revealFrames
    }

    private var sign: RoadSignArtwork { RoadSignArtwork(width: width, height: height) }

    static var designWidth: Double { RoadSignArtwork.designWidth }
    static var designHeight: Double { RoadSignArtwork.designHeight }

    /// Width and height for rendering at 80% of a 4K screen's width, with
    /// height scaled to preserve the sign's design aspect ratio.
    static var wideScreenSize: (width: Int, height: Int) { RoadSignArtwork.wideScreenSize }

    /// The height that preserves the design aspect ratio for a given width.
    static func height(forWidth width: Int) -> Int { RoadSignArtwork.height(forWidth: width) }

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
        RoadSignArtwork.splitTitle(title)
    }

    /// Precomputed once and reused across frames: the bare badge with no
    /// credit line, road number, or destinations (used while fading in, and
    /// as the base for every spin frame, since the number and destinations
    /// there change every frame), and the sign with the real road number and
    /// destinations added on top but the credit line still absent (used
    /// unchanged for the reveal, until the credit line fades in on top of it
    /// part-way through and stays for the rest of the clip).
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
        sign.drawBadge(into: blankBadgeContext)
        guard let blankBadge = blankBadgeContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let revealedContext = try LayerCompositor.bitmapContext(width: width, height: height)
        revealedContext.draw(blankBadge, in: canvas)
        sign.drawDestinations(title, into: revealedContext)
        sign.drawNumber(roadText, into: revealedContext)
        guard let revealed = revealedContext.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }

        let spinSequence = (0..<Self.spinFrames).compactMap { _ in spinEntries.randomElement() }

        return Artwork(blankBadge: blankBadge, revealed: revealed, spinSequence: spinSequence)
    }

    // MARK: - Drawing

    /// Draws frame `index` into `context`: the sign fading in, the spin,
    /// then the reveal - held for the rest of the clip, with the credit
    /// line fading in on top of it partway through.
    ///
    /// The spin's digits (and, when `artwork.spinSequence` isn't empty, its
    /// destinations) are drawn fresh for every frame, directly into
    /// `context` on top of the opaque sign, since full-opacity draws can be
    /// layered safely; the fade-in instead draws a single pre-flattened
    /// image, since fading the sign and text separately at the same
    /// fractional alpha would double-blend where they overlap. The credit
    /// line fades in the same direct way, since it never overlaps the
    /// number or destinations it's drawn on top of.
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
                sign.drawNumber(
                    Self.randomRoadText(roadType: roadType, digitCount: String(roadNumber).count),
                    into: context)
            } else {
                let entry = artwork.spinSequence[spinIndex % artwork.spinSequence.count]
                context.draw(artwork.blankBadge, in: canvas)
                sign.drawNumber(entry.roadText, into: context)
                sign.drawDestinations(entry.title, into: context)
            }
        } else {
            context.draw(artwork.revealed, in: canvas)
            let revealFrame = frameIndex - Self.fadeInFrames - Self.spinFrames
            let creditFrame = revealFrame - Self.creditFadeInDelayFrames
            if creditFrame >= Self.creditFadeInFrames {
                sign.drawCreditLine(into: context)
            } else if creditFrame >= 0 {
                let fraction = Double(creditFrame) / Double(Self.creditFadeInFrames - 1)
                context.setAlpha(fraction)
                sign.drawCreditLine(into: context)
                context.setAlpha(1)
            }
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
