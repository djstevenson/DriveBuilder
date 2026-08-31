import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import DriveBuilder

private func colour(_ frame: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
    frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// The border green is #669933.
private func isBorderGreen(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return abs(colour.redComponent - 0.4) < 0.1 && abs(colour.greenComponent - 0.6) < 0.1
        && abs(colour.blueComponent - 0.2) < 0.1 && colour.alphaComponent > 0.9
}

private func isBlack(_ colour: NSColor?) -> Bool {
    guard let colour else { return false }
    return colour.redComponent < 0.1 && colour.greenComponent < 0.1
        && colour.blueComponent < 0.1 && colour.alphaComponent > 0.9
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

@Test func bannerOpensFromTwoLinesMeetingAtTheCentre() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // At t = 0 the two lines coincide at the centre; everything else is
    // transparent.
    let first = try renderer.frame(at: 0, artwork: artwork)
    #expect(isBorderGreen(colour(first, 10, 80)))
    #expect(isTransparent(colour(first, 10, 70)))
    #expect(isTransparent(colour(first, 10, 90)))
    #expect(isTransparent(colour(first, 10, 0)))
    #expect(isTransparent(colour(first, 10, 159)))
}

@Test func openBannerHasGreenEdgesAndABlackBand() throws {
    let renderer = AnnotationRenderer(text: "Test")
    let artwork = try renderer.makeArtwork()

    // t = 1s: fully open, text still near the right edge, so the left side
    // shows the plain banner: green top and bottom rows, black between.
    let frame = try renderer.frame(at: 30, artwork: artwork)
    #expect(isBorderGreen(colour(frame, 100, 0)))
    #expect(isBorderGreen(colour(frame, 100, 1)))
    #expect(isBlack(colour(frame, 100, 80)))
    #expect(isBorderGreen(colour(frame, 100, 158)))
    #expect(isBorderGreen(colour(frame, 100, 159)))
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
    let file = FileManager.default.temporaryDirectory
        .appending(path: "annotation-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(
        """
        Crowmarsh Gifford,
        where the A4130 crosses the Thames.

        Often congested.

        """.utf8
    ).write(to: file)

    #expect(
        try DriveBuilder.Annotations.annotationText(from: file)
            == "Crowmarsh Gifford, where the A4130 crosses the Thames. Often congested.")
}

@Test func annotationFilesRequireTheDirectoryAndAtLeastOneTxt() throws {
    let journey = FileManager.default.temporaryDirectory
        .appending(path: "annotations-journey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: journey, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: journey) }
    let journeyPath = journey.path(percentEncoded: false)

    // No annotations directory at all.
    #expect(throws: ValidationError.self) {
        try DriveBuilder.Annotations.annotationFiles(in: journeyPath)
    }

    // An annotations directory with no .txt files.
    let annotations = journey.appending(path: "annotations")
    try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
    try Data("not an annotation".utf8).write(to: annotations.appending(path: "notes.md"))
    #expect(throws: ValidationError.self) {
        try DriveBuilder.Annotations.annotationFiles(in: journeyPath)
    }

    // Two .txt files come back sorted by name.
    try Data("B".utf8).write(to: annotations.appending(path: "Second Bend.txt"))
    try Data("A".utf8).write(to: annotations.appending(path: "Crowmarsh Roundabout.txt"))
    let files = try DriveBuilder.Annotations.annotationFiles(in: journeyPath)
    #expect(
        files.map(\.lastPathComponent) == ["Crowmarsh Roundabout.txt", "Second Bend.txt"])
}
