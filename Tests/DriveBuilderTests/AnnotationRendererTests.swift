import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
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

@Test func openBandLinesUpWithTheDialGrid() {
    // The 3840 px frame less the 20 px edge inset on each side, the 696 px
    // dial column, and the 16 px grid gap before it.
    #expect(AnnotationRenderer.rightMargin == 16)
    #expect(AnnotationRenderer(text: "Test").width == 3088)
}

@Test func framePlanCoversOpenScrollCloseAndATransparentTail() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let textWidth = AnnotationRenderer.textWidth(of: renderer.textLine)

    let duration = 0.7 + Double(3088 + textWidth) / 540.0 + 0.7
    #expect(renderer.frameCount == Int((duration * 30).rounded(.up)) + 1)
    // The advance of "Test" in bold 92px Helvetica plus the padding.
    #expect(textWidth > 200)
    #expect(textWidth < 500)
}

@Test func bandWidensOutOfItsRightEdge() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // At t = 0 the band hasn't opened, so the whole frame is transparent.
    let first = try renderer.frame(at: 0, artwork: artwork)
    for (x, y) in [(0, 0), (1544, 80), (3087, 159)] {
        #expect(isTransparent(colour(first, x, y)))
    }

    // Partway open (frame 10, progress p = 10/21, eased to
    // p² (3 - 2p) ≈ 0.4643): the band is 3088 * 0.4643, rounded: 1434 px
    // wide, anchored right at columns 1654-3087, full height.
    let opening = try renderer.frame(at: 10, artwork: artwork)
    for y in [0, 80, 159] {
        #expect(isTransparent(colour(opening, 1653, y)))
        #expect(isBackground(colour(opening, 1654, y)))
        #expect(isBackground(colour(opening, 3087, y)))
    }

    // Eased: the second frame has moved the edge only a few columns
    // (3088 * smoothstep(1/21) ≈ 20), where constant speed would be 148.
    let second = try renderer.frame(at: 1, artwork: artwork)
    #expect(isBackground(colour(second, 3087 - 15, 80)))
    #expect(isTransparent(colour(second, 3087 - 30, 80)))
}

@Test func bandCollapsesIntoItsLeftEdge() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // A few frames before the transparent tail the band is narrow, its
    // right edge having swept most of the way across to the left edge.
    let closing = try renderer.frame(at: renderer.frameCount - 4, artwork: artwork)
    #expect(isBackground(colour(closing, 0, 80)))
    #expect(isTransparent(colour(closing, 3087, 80)))
    #expect(isTransparent(colour(closing, 1544, 80)))
}

@Test func openBandIsTranslucentToItsEdges() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // t = 1s: fully open, text still near the right edge, so the left side
    // shows the plain band from the top row to the bottom row, starting at
    // the very first column.
    let frame = try renderer.frame(at: 30, artwork: artwork)
    for y in [0, 1, 80, 158, 159] {
        #expect(isBackground(colour(frame, 0, y)))
        #expect(isBackground(colour(frame, 100, y)))
    }
}

@Test func textScrollsAcrossInYellow() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // t ≈ 4.47s: the text (which entered at the right edge at t = 0.7 and
    // scrolls at 540 px/s) starts at x = 3088 - 3.77 * 540 ≈ 1052, well
    // inside the frame.
    let frame = try renderer.frame(at: 134, artwork: artwork)
    var sawYellow = false
    for y in 10..<150 {
        for x in stride(from: 1000, to: 1600, by: 2) {
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
    for (x, y) in [(0, 0), (1544, 80), (3087, 159), (100, 1), (100, 158)] {
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

