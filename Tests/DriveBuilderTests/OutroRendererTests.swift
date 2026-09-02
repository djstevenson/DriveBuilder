import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

private func isWhite(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent > 0.85 && colour.greenComponent > 0.85
        && colour.blueComponent > 0.85 && colour.alphaComponent > 0.9
}

private func isYellow(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent > 0.8 && colour.greenComponent > 0.8
        && colour.blueComponent < 0.3 && colour.alphaComponent > 0.9
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

/// True if `colour` is a fully opaque blend of the sign's green and white
/// text, `whiteFraction` of the way from green to white - the look of the
/// credit line fading in or out over the sign's already-opaque green
/// interior (rather than its own alpha channel changing, since there's no
/// transparency left to carry that).
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

private let creditBandYRange = 433...461
private let destinationBandYRange = 341...425

@Test func frameCountCoversAllFourPhases() {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    #expect(renderer.frameCount == 90 + 20 + 15 + 90)
}

@Test func firstFrameShowsTheRealRoadNumberDestinationsAndCredit() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: 0, artwork: artwork)

    #expect(hasYellowNearCentre(frame))
    #expect(hasInk(frame, bitmapYRange: destinationBandYRange) { isWhite($0) })
    #expect(hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

@Test func creditLineStaysFullyVisibleRightUpToTheTextChange() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: OutroRenderer.initialHoldFrames - 1, artwork: artwork)

    #expect(hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

@Test func creditLineStaysFullyVisibleDuringTheTextChange() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: OutroRenderer.initialHoldFrames + OutroRenderer.textChangeFrames / 2, artwork: artwork)

    // The road number and destinations are mid cross-fade, but the credit
    // line is drawn separately every frame and isn't touched by that.
    #expect(hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

@Test func signOffTextIsFullyShownOnceTheTextChangeCompletes() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: OutroRenderer.initialHoldFrames + OutroRenderer.textChangeFrames, artwork: artwork)

    #expect(hasYellowNearCentre(frame))
    #expect(hasInk(frame, bitmapYRange: destinationBandYRange) { isWhite($0) })
    // The credit fade-out window has just begun, at fraction 1: still fully
    // opaque white.
    #expect(hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

@Test func creditLineFadesOutPartwayThroughItsWindow() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    // 7 of 15 credit-fade frames in: fraction 1 - 7/14 = 0.5 white.
    let frame = try renderer.frame(
        at: OutroRenderer.initialHoldFrames + OutroRenderer.textChangeFrames + 7, artwork: artwork)

    #expect(hasInk(frame, bitmapYRange: creditBandYRange) { isGreenWhiteBlend($0, whiteFraction: 7.0 / 14.0) })
}

@Test func creditLineIsGoneOnceItsFadeOutCompletes() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(
        at: OutroRenderer.initialHoldFrames + OutroRenderer.textChangeFrames
            + OutroRenderer.creditFadeOutFrames, artwork: artwork)

    #expect(!hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

@Test func finalHoldShowsTheSignOffTextWithNoCredit() throws {
    let renderer = OutroRenderer(roadType: "A", roadNumber: 3088, title: "Caversham to Littlemore")
    let artwork = try renderer.makeArtwork()
    let frame = try renderer.frame(at: renderer.frameCount - 1, artwork: artwork)

    #expect(hasYellowNearCentre(frame))
    #expect(hasInk(frame, bitmapYRange: destinationBandYRange) { isWhite($0) })
    #expect(!hasInk(frame, bitmapYRange: creditBandYRange) { isWhite($0) })
}

/// An end-to-end check that the outro command reads the road straight from
/// the bundled database rather than a command-line option. Journey 1 is the
/// project's checked-in database, so these numbers only change if that data
/// is replaced.
@Test func outroUsesTheJourneysRoadFromTheDatabase() throws {
    let outro = try DriveBuilder.Outro.parse(["-j", "1"])
    let road = try outro.telemetry.journeyRoad()
    #expect(road.type == "A")
    #expect(road.number == 338)
}
