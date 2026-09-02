import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

private func isTransparent(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.alphaComponent < 0.01
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
    #expect(isTransparent(colour(frame, 40, 1052)))
    #expect(isGreen(colour(frame, 108, 1052)))
    #expect(isGreen(colour(frame, 1680, 1052)))
}

@Test func roadTextCombinesTypeAndNumber() {
    #expect(IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive").roadText == "A3088")
    #expect(IntroRenderer(roadType: "A", roadNumber: 1, title: "Test Drive").roadText == "A1")
    #expect(
        IntroRenderer(roadType: "B", roadNumber: 9999, title: "Test Drive").roadText == "B9999")
}

@Test func frameCountCoversAllFourPhases() {
    #expect(IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive").frameCount == 10 + 60 + 90 + 10)
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

@Test func firstFadeInFrameIsFullyTransparent() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: 0, artwork: artwork)

    #expect(isTransparent(colour(frame, 420, 160)))
    #expect(isTransparent(colour(frame, 27, 160)))
}

@Test func midFadeInFrameIsPartiallyTransparent() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Frame 5 of 10 fade-in frames: fraction 5/9.
    let frame = try renderer.frame(at: 5, artwork: artwork)

    #expect(isGreen(colour(frame, 420, 160), alpha: 5.0 / 9.0))
}

@Test func openBadgeShowsNestedGreenWhiteGreenBands() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Last fade-in frame: fully opaque badge, no text yet.
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    #expect(isTransparent(colour(frame, 10, 160)))
    #expect(isGreen(colour(frame, 27, 160)))
    #expect(isWhite(colour(frame, 35, 160)))
    #expect(isGreen(colour(frame, 420, 160)))
    #expect(isWhite(colour(frame, 805, 160)))
    #expect(isGreen(colour(frame, 813, 160)))
    #expect(isTransparent(colour(frame, 830, 160)))
}

@Test func openBadgeShowsTheCreditLineWithTheDestinationsStillBlank() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Last fade-in frame: fully opaque. On the default canvas the two
    // destination-line rows are bitmap rows 341...425, top-left origin, and
    // the credit line's row is 433...461, both inside the sign itself. The
    // destinations only appear once the spin starts, so they're still blank
    // here; the credit line fades in with the sign.
    let frame = try renderer.frame(at: IntroRenderer.fadeInFrames - 1, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: 341...425) { isWhite($0) })
    #expect(hasInk(frame, bitmapYRange: 433...461) { isWhite($0) })
}

@Test func creditLineFadesInWithTheBadgeWhileDestinationsStayBlank() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    // Frame 5 of 10 fade-in frames: fraction 5/9, matching
    // midFadeInFrameIsPartiallyTransparent's check on the badge itself.
    let frame = try renderer.frame(at: 5, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: 341...425) { isWhite($0) })
    #expect(hasInk(frame, bitmapYRange: 433...461) { isWhite($0, alpha: 5.0 / 9.0) })
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
    // near the top.
    #expect(isTransparent(colour(frame, 420, 20)))
    #expect(isGreen(colour(frame, 420, 32)))
    #expect(isTransparent(colour(frame, 420, 506)))
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

@Test func fadeOutEndsFullyTransparent() throws {
    let renderer = IntroRenderer(roadType: "A", roadNumber: 3088, title: "Test Drive")
    let artwork = try renderer.makeArtwork()
    let last = try renderer.frame(at: renderer.frameCount - 1, artwork: artwork)

    #expect(isTransparent(colour(last, 420, 160)))
    #expect(isTransparent(colour(last, 27, 160)))
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
