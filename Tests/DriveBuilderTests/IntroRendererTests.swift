import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// True if `colour` is fully opaque but not one of the sign's own colours -
/// i.e. a pixel of the full-bleed background image (dark backdrop or pale
/// line-art stroke) showing where the sign isn't drawn.
private func isBackground(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.alphaComponent > 0.99 && !isGreen(colour) && !isWhite(colour)
}

private func isGreen(_ colour: NSColor?, alpha: Double = 1) -> Bool {
    guard let colour else { return false }
    return colour.redComponent < 0.15 && abs(colour.greenComponent - 0.502) < 0.1
        && colour.blueComponent < 0.15 && abs(colour.alphaComponent - alpha) < 0.1
}

private func isWhite(_ colour: NSColor?, alpha: Double = 1) -> Bool {
    guard let colour else { return false }
    return colour.redComponent > 0.85 && colour.greenComponent > 0.85
        && colour.blueComponent > 0.85 && abs(colour.alphaComponent - alpha) < 0.1
}

private func isYellow(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent > 0.8 && colour.greenComponent > 0.8
        && colour.blueComponent < 0.3 && colour.alphaComponent > 0.9
}

private func isMidGrey(_ colour: NSColor?, alpha: Double = 1) -> Bool {
    guard let colour else { return false }
    return abs(colour.redComponent - 0.5) < 0.05 && abs(colour.greenComponent - 0.5) < 0.05
        && abs(colour.blueComponent - 0.5) < 0.05 && abs(colour.alphaComponent - alpha) < 0.1
}

/// True if `colour` is a fully opaque blend of the sign's green and white
/// text, `fraction` of the way from green to white - the look of white text
/// fading in over the sign's already-opaque green interior (rather than the
/// text's own alpha channel dropping, since there's no transparency left to
/// carry that).
private func isGreenWhiteBlend(_ colour: NSColor?, whiteFraction: Double) -> Bool {
    guard let colour else { return false }
    let expectedRed = whiteFraction
    let expectedGreen = 0.502 + (1 - 0.502) * whiteFraction
    let expectedBlue = whiteFraction
    return abs(colour.redComponent - expectedRed) < 0.1
        && abs(colour.greenComponent - expectedGreen) < 0.1
        && abs(colour.blueComponent - expectedBlue) < 0.1
        && abs(colour.alphaComponent - 1) < 0.1
}

/// True if any sampled pixel in the horizontal band around vertical centre
/// is yellow ink, without depending on exactly where a proportional font
/// places any particular glyph.
private func hasYellowNearCentre(_ frame: NSBitmapImageRep) -> Bool {
    for y in stride(from: 100, through: 220, by: 4) {
        for x in stride(from: 100, through: 740, by: 4) {
            if isYellow(colour(frame, x, y)) { return true }
        }
    }
    return false
}

/// True if any pixel in the horizontal strip `bitmapYRange` (top-left-origin,
/// matching `NSBitmapImageRep.colorAt`) matches `predicate`, without
/// depending on exactly where a proportional font places any particular
/// glyph.
private func hasInk(
    _ frame: NSBitmapImageRep, bitmapYRange: ClosedRange<Int>,
    matching predicate: (NSColor?) -> Bool
) -> Bool {
    for y in bitmapYRange {
        for x in stride(from: 100, through: 740, by: 4) {
            if predicate(colour(frame, x, y)) { return true }
        }
    }
    return false
}

@Test func wideScreenSizeIs80PercentOf4KWidePreservingAspectRatio() {
    let size = IntroRenderer.wideScreenSize
    #expect(size.width == 3072)
    #expect(size.height == IntroRenderer.height(forWidth: 3072))
    // Matches the sign's 840:526 design ratio to within a rounded pixel.
    #expect(
        abs(
            Double(size.width) / Double(size.height)
                - IntroRenderer.designWidth / IntroRenderer.designHeight) < 0.001)
}

@Test func badgeScalesUpWithTheCanvasSize() throws {
    // At 4x the design size, the sign's opaque interior should show at 4x
    // the design coordinates too.
    var renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    renderer.width = 3360
    renderer.height = IntroRenderer.height(forWidth: 3360)
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    // y=1052 is 4x the design sign's vertical centre (263).
    #expect(isBackground(colour(frame, 40, 1052)))
    #expect(isGreen(colour(frame, 108, 1052)))
    #expect(isGreen(colour(frame, 1680, 1052)))
}

@Test func roadTextCombinesTypeAndNumber() {
    #expect(IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive").roadText == "A3088")
    #expect(IntroRenderer(roadType: "A", roadNumber: 1, title: "Test Drive").roadText == "A1")
    #expect(
        IntroRenderer(roadType: "B", roadNumber: 9999, title: "Test Drive").roadText == "B9999")
}

@Test func frameCountCoversAllThreePhases() {
    #expect(IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive").frameCount == 10 + 60 + 90)
}

@Test func randomRoadTextMatchesTheRequestedDigitCount() {
    for digitCount in 1...4 {
        for _ in 0..<300 {
            let text = IntroRenderer.randomRoadText(roadType: "A", digitCount: digitCount)
            #expect(text.count == digitCount + 1)
            #expect(text.first == "A")
            let digits = Array(text.dropFirst())
            #expect(("1"..."9").contains(digits[0]))
            for digit in digits.dropFirst() {
                #expect(("0"..."9").contains(digit))
            }
        }
    }
}

@Test func firstFadeInFrameShowsOnlyTheBackgroundImage() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: 0, artwork: artwork)

    // The sign is at alpha 0, so both these points - one where its green
    // interior will be, one where its outer green ring will be - show the
    // opaque background image instead.
    #expect(isBackground(colour(frame, 420, 160)))
    #expect(isBackground(colour(frame, 27, 160)))
}

@Test func midFadeInFrameBlendsTheBadgeOverTheBackground() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Frame 5 of 10 fade-in frames: the badge at alpha 5/9 over the opaque
    // background, so the frame stays fully opaque and the colour lands 5/9
    // of the way from the background pixel (sampled from frame 0, where the
    // badge is still at alpha 0) to the badge's green.
    let background = try #require(colour(renderer.frame(at: 0, artwork: artwork), 420, 160))
    let blended = try #require(colour(renderer.frame(at: 5, artwork: artwork), 420, 160))

    let fraction = 5.0 / 9.0
    #expect(abs(blended.alphaComponent - 1) < 0.02)
    #expect(abs(blended.redComponent - background.redComponent * (1 - fraction)) < 0.05)
    #expect(
        abs(
            blended.greenComponent
                - (background.greenComponent * (1 - fraction) + 0.502 * fraction)) < 0.05)
    #expect(abs(blended.blueComponent - background.blueComponent * (1 - fraction)) < 0.05)
}

@Test func openBadgeShowsNestedGreenWhiteGreenBands() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Last fade-in frame: fully opaque badge, no text yet.
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    #expect(isBackground(colour(frame, 10, 160)))
    #expect(isGreen(colour(frame, 27, 160)))
    #expect(isWhite(colour(frame, 35, 160)))
    #expect(isGreen(colour(frame, 420, 160)))
    #expect(isWhite(colour(frame, 805, 160)))
    #expect(isGreen(colour(frame, 813, 160)))
    #expect(isBackground(colour(frame, 830, 160)))
}

@Test func openBadgeShowsNeitherTheDestinationsNorTheCreditLine() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Last fade-in frame: fully opaque badge. On the default canvas the two
    // destination-line rows are bitmap rows 341...425, top-left origin, and
    // the credit line's row is 433...461, both inside the sign itself. Both
    // stay blank until later: destinations appear once the spin starts, and
    // the credit line only fades in partway through the reveal.
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: 341...425) { isWhite($0) })
    #expect(!hasInk(frame, bitmapYRange: 433...461) { isWhite($0) })
}

@Test func creditLineStaysBlankThroughTheSpin() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames + 10, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: 433...461) { isWhite($0) })
}

@Test func spinFrameShowsRandomDigitsOverTheOpenBadge() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames + 10, artwork: artwork)

    #expect(isGreen(colour(frame, 27, 160)))
    #expect(hasYellowNearCentre(frame))
}

/// With spin entries supplied, the spin phase should show a spin entry's
/// destinations even though they stay blank while fading in. Using a
/// non-empty spin title makes "some destination text is showing during the
/// spin" easy to detect against the blank fade-in.
@Test func spinTitleAnimatesWithTheSpinningRoadWhenEntriesAreSupplied() throws {
    var renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    renderer.spinEntries = [IntroRenderer.SpinEntry(roadText: "A4074", title: "Somewhere to Else")]
    let artwork = try renderer.makeArtwork()

    let fadeInFrame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)
    #expect(!hasInk(fadeInFrame, bitmapYRange: 341...425) { isWhite($0) })

    let spinFrame = try renderer.frame(at: IntroRenderer.fadeInFrames + 10, artwork: artwork)
    #expect(isGreen(colour(spinFrame, 27, 160)))
    #expect(hasYellowNearCentre(spinFrame))
    #expect(hasInk(spinFrame, bitmapYRange: 341...425) { isWhite($0) })
}

@Test func splitTitleDividesOnTheToKeyword() {
    let (first, second) = IntroRenderer.splitTitle("Caversham to Littlemore")
    #expect(first == "Caversham")
    #expect(second == "Littlemore")
}

@Test func splitTitleFallsBackToTheWholeTitleWhenThereIsNoToKeyword() {
    let (first, second) = IntroRenderer.splitTitle("Just One Place")
    #expect(first == "Just One Place")
    #expect(second == "")
}

@Test func revealFrameShowsDestinationsAsLeftAlignedTextInsideTheSign() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: IntroRenderer.fadeInFrames + IntroRenderer.spinFrames + 5, artwork: artwork)

    // Both destination lines sit inside the sign, left-aligned rather than
    // centred, so ink shows up near the left content inset (bitmap x=96 on
    // the default canvas) rather than around the canvas centre (x=420).
    #expect(hasInk(frame, bitmapYRange: 341...383) { isWhite($0) })
    #expect(hasInk(frame, bitmapYRange: 383...425) { isWhite($0) })
}

@Test func signIsCentredVerticallyOnTheCanvas() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Last fade-in frame: fully opaque sign.
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    // The visible sign's outer edge sits 30px in from the canvas edge on
    // both the top and the bottom, since it's centred rather than pinned
    // near the top; the background image shows in the margins.
    #expect(isBackground(colour(frame, 420, 20)))
    #expect(isGreen(colour(frame, 420, 32)))
    #expect(isBackground(colour(frame, 420, 506)))
    #expect(isGreen(colour(frame, 420, 494)))
}

@Test func revealFrameShowsTheRealRoadNumber() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: IntroRenderer.fadeInFrames + IntroRenderer.spinFrames + 5, artwork: artwork)

    #expect(isGreen(colour(frame, 27, 160)))
    #expect(hasYellowNearCentre(frame))
}

@Test func creditLineIsStillBlankRightAfterTheReveal() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: IntroRenderer.fadeInFrames + IntroRenderer.spinFrames + 5, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: 433...461) { isWhite($0) })
}

@Test func creditLineFadesInPartwayThroughTheReveal() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // 7 of 15 credit-fade frames in, after the delay: fraction 7/14.
    let frame = try renderer.frame(
        at: IntroRenderer.fadeInFrames + IntroRenderer.spinFrames
            + IntroRenderer.creditFadeInDelayFrames + 7, artwork: artwork)

    #expect(hasInk(frame, bitmapYRange: 433...461) { isGreenWhiteBlend($0, whiteFraction: 7.0 / 14.0) })
}

@Test func creditLineIsFullyOpaqueOnceItsFadeCompletes() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: IntroRenderer.fadeInFrames + IntroRenderer.spinFrames
            + IntroRenderer.creditFadeInDelayFrames + IntroRenderer.creditFadeInFrames + 5,
        artwork: artwork)

    #expect(hasInk(frame, bitmapYRange: 433...461) { isWhite($0) })
}

@Test func lastFrameHoldsTheRevealedSignAtFullOpacity() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let last = try renderer.frame(at: renderer.frameCount - 1, artwork: artwork)

    #expect(isGreen(colour(last, 420, 160)))
    #expect(isGreen(colour(last, 27, 160)))
}

/// An end-to-end check that the intro command reads the road straight from
/// the bundled database rather than a command-line option. Journey 1 is the
/// project's checked-in database, so these numbers only change if that data
/// is replaced.
@Test func introUsesTheJourneysRoadFromTheDatabase() throws {
    let intro = try DriveBuilder.Intro.parse(["-j", "1"])
    let road = try intro.telemetry.journeyRoad()
    #expect(road.type == "A")
    #expect(road.number == 338)
}
