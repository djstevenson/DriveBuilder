import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// `AnnotationRenderer.borderColour` is sRGB (0, 0x99, 0); converting that
/// through `usingColorSpace(.deviceRGB)` on this OS yields (0, 0.6, 0)
/// unchanged, rather than the muted (0.4, 0.6, 0.2) an older macOS produced
/// for the same source colour.
private func isBorderGreen(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent < 0.1 && abs(colour.greenComponent - 0.6) < 0.1
        && colour.blueComponent < 0.1 && colour.alphaComponent > 0.9
}

/// The band's translucent background: black at the dials' 60% alpha.
private func isBackground(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent < 0.1 && colour.greenComponent < 0.1
        && colour.blueComponent < 0.1 && abs(colour.alphaComponent - 0.6) < 0.05
}

private func isTransparent(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.alphaComponent < 0.01
}

@Test func framePlanCoversOpenScrollCloseAndATransparentTail() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let textWidth = AnnotationRenderer.textWidth(of: renderer.textLine)

    let duration = 0.7 + Double(3840 + textWidth) / 540.0 + 0.7
    #expect(renderer.frameCount == Int((duration * 30).rounded(.up)) + 1)
    // The advance of "Test" in bold 92px Helvetica plus the padding.
    #expect(textWidth > 200)
    #expect(textWidth < 500)
}

@Test func bannerRisesInFromBelowTheBottomEdge() throws {
    var renderer = AnnotationRenderer(text: "Test")
    renderer.showsBorderLines = true
    let artwork = try renderer.makeArtwork()

    // At t = 0 both lines sit one row below the canvas — off the bottom of
    // the video — so the whole frame is transparent.
    let first = try renderer.frame(at: 0, artwork: artwork)
    for y in [0, 80, 158, 169] {
        #expect(isTransparent(colour(first, 10, y)))
    }

    // One frame in, the pair has risen into the inset region, still
    // coincident: 4 rows starting at 170 * (1 - (1/30) / 0.7), rounded:
    // rows 162-165.
    let rising = try renderer.frame(at: 1, artwork: artwork)
    #expect(isTransparent(colour(rising, 10, 161)))
    #expect(isBorderGreen(colour(rising, 10, 162)))
    #expect(isBorderGreen(colour(rising, 10, 165)))
    #expect(isTransparent(colour(rising, 10, 166)))
    #expect(isTransparent(colour(rising, 10, 100)))

    // Partway through the open (frame 10, progress 10/21): the top line has
    // climbed to row 170 * (1 - 10/21), rounded: 89; the bottom line rests
    // at rows 156-159 with the background between, and the inset below stays clear.
    let opening = try renderer.frame(at: 10, artwork: artwork)
    #expect(isBorderGreen(colour(opening, 10, 89)))
    #expect(isBackground(colour(opening, 10, 120)))
    #expect(isBorderGreen(colour(opening, 10, 156)))
    #expect(isBorderGreen(colour(opening, 10, 159)))
    #expect(isTransparent(colour(opening, 10, 165)))
    #expect(isTransparent(colour(opening, 10, 50)))
}

@Test func openBannerHasGreenEdgesAndATranslucentBand() throws {
    var renderer = AnnotationRenderer(text: "Test")
    renderer.showsBorderLines = true
    let artwork = try renderer.makeArtwork()

    // t = 1s: fully open, text still near the right edge, so the left side
    // shows the plain banner: green top and bottom rows, translucent background between, and
    // the bottom inset transparent so the video shows through beneath.
    let frame = try renderer.frame(at: 30, artwork: artwork)
    #expect(isBorderGreen(colour(frame, 100, 0)))
    #expect(isBorderGreen(colour(frame, 100, 1)))
    #expect(isBackground(colour(frame, 100, 80)))
    #expect(isBorderGreen(colour(frame, 100, 158)))
    #expect(isBorderGreen(colour(frame, 100, 159)))
    #expect(isTransparent(colour(frame, 100, 165)))
    #expect(isTransparent(colour(frame, 100, 169)))
}

@Test func borderlessBannerIsBackgroundToItsEdges() throws {
    let renderer = AnnotationRenderer(text: "Test")
    #expect(!renderer.showsBorderLines)
    let artwork = try renderer.makeArtwork()

    // No inset: the band sits on the video's bottom edge.
    #expect(renderer.height == 160)

    // Fully open: the background reaches the band's top and bottom rows,
    // where the green lines would be, down to the canvas's last row.
    let open = try renderer.frame(at: 30, artwork: artwork)
    for y in [0, 1, 80, 158, 159] {
        #expect(isBackground(colour(open, 100, y)))
    }

    // Partway open (frame 10, progress 10/21): the band's top edge has
    // risen to row 160 * (1 - 10/21), rounded: 84, with nothing above it.
    let opening = try renderer.frame(at: 10, artwork: artwork)
    #expect(isTransparent(colour(opening, 10, 83)))
    #expect(isBackground(colour(opening, 10, 84)))
    #expect(isBackground(colour(opening, 10, 159)))
}

@Test func textScrollsAcrossInYellow() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // t ≈ 4.47s: the text (which entered at the right edge at t = 0.7 and
    // scrolls at 540 px/s) sits around x = 1806, well inside the frame.
    let frame = try renderer.frame(at: 134, artwork: artwork)
    var sawYellow = false
    for y in 10..<150 {
        for x in stride(from: 1700, to: 2600, by: 2) {
            guard let colour = colour(frame, x, y) else { continue }
            if colour.redComponent > 0.8 && colour.greenComponent > 0.8
                && colour.blueComponent < 0.3
            {
                sawYellow = true
            }
        }
    }
    #expect(sawYellow)
}

@Test func finalFrameIsFullyTransparent() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    let last = try renderer.frame(at: renderer.frameCount - 1, artwork: artwork)
    for (x, y) in [(0, 0), (1920, 80), (3839, 159), (100, 1), (100, 158)] {
        #expect(isTransparent(colour(last, x, y)))
    }
}

@Test func lineBreaksInTheAnnotationBecomeSpaces() throws {
    let text = """
        Crowmarsh Gifford,
        where the A4130 crosses the Thames.

        Often congested.

        """

    #expect(
        DriveBuilder.Annotations.normalizedText(text)
            == "Crowmarsh Gifford, where the A4130 crosses the Thames. Often congested.")
}

