import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import DriveBuilder

/// Writes a `seconds`-long, 30 fps ProRes movie, each frame filled with
/// `colour(frameIndex)`.
private func writeClip(
    _ url: URL, width: Int, height: Int, seconds: Double,
    colour: @escaping (Int) -> CGColor
) async throws {
    let writer = AlphaMovieWriter(url: url, width: width, height: height, framesPerSecond: 30)
    try await writer.write(frameCount: Int(seconds * 30)) { index, context in
        context.setFillColor(colour(index))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// The 0...255 RGB of `image` at (`x`, `y`), top-left origin.
private func rgb(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
    let context = try LayerCompositor.bitmapContext(width: 1, height: 1)
    context.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])]
}

private func frame(of url: URL, at seconds: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

private let grey = CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let magenta = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

/// A journey's worth of tiny clips: 1 s intro, route map (sets the 4K
/// frame), outro, transparent dials, grey front footage, and a blue rear
/// view. With 0.5 s cross-fades the route map runs from 0.5 s to 1.5 s and
/// the drive segment from 1 s to 6 s (raw front.mov 0 s is 1 s in the final
/// video); the outro starts fading in at 5.5 s.
private func writeCommonClips(in directory: URL) async throws {
    func url(_ name: String) -> URL { directory.appending(path: name) }
    try await writeClip(url("intro.mov"), width: 64, height: 36, seconds: 1) { _ in grey }
    try await writeClip(url("outro.mov"), width: 64, height: 36, seconds: 1) { _ in grey }
    try await writeClip(url("route_map.mov"), width: 3840, height: 2160, seconds: 1) { _ in grey }
    try await writeClip(url("dials.mov"), width: 64, height: 196, seconds: 5) { _ in
        CGColor(gray: 0, alpha: 0)
    }
    try await writeClip(url("front.mov"), width: 640, height: 360, seconds: 5) { _ in grey }
    try await writeClip(url("rear.mov"), width: 960, height: 540, seconds: 5) { _ in blue }
}

private func composer(in directory: URL) -> FinalVideoComposer {
    func url(_ name: String) -> URL { directory.appending(path: name) }
    var composer = FinalVideoComposer(
        introURL: url("intro.mov"), routeMapURL: url("route_map.mov"),
        dialsURL: url("dials.mov"), frontFootageURL: url("front.mov"),
        rearFootageURL: url("rear.mov"), outroURL: url("outro.mov"))
    composer.crossFadeSeconds = 0.5
    return composer
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "final-composer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Within 40 of `expected` on every channel (the HEVC export isn't exact).
private func isClose(_ pixel: [Int], to expected: [Int]) -> Bool {
    zip(pixel, expected).allSatisfy { abs($0 - $1) <= 40 }
}

private func override(
    _ camera: CameraOverride.Camera, _ start: Double, _ end: Double, label: String? = nil
) -> CameraOverride {
    CameraOverride(id: 0, journeyID: 1, camera: camera, start: start, end: end, label: label)
}

// The slot is the rear view's frame: 960x540 at (20, 20). Its middle is
// (500, 290); its label sits in the top-left corner, 52 px tall.
private let slotMiddle = (500, 290)

/// How far right the slot's label band reaches, scanning its middle row:
/// the band darkens the tile beneath it.
private func labelWidth(in image: CGImage, tileColour: [Int]) throws -> Int {
    var x = 20
    while x < 980, !isClose(try rgb(image, x, 46), to: tileColour) { x += 4 }
    return x - 20
}

@Test(.timeLimit(.minutes(2)))
func cameraOverridesSwapTheSlotInSyncWithLabels() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await writeCommonClips(in: directory)
    // The left camera started recording 1 s early: magenta for that second,
    // then green once in sync. It's shorter than the journey, which is fine:
    // it only has to cover its window.
    try await writeClip(
        directory.appending(path: "left.mov"), width: 960, height: 540, seconds: 4
    ) { $0 < 30 ? magenta : green }
    try await writeClip(
        directory.appending(path: "right.mov"), width: 960, height: 540, seconds: 5
    ) { _ in red }

    var composer = composer(in: directory)
    composer.startOffsets.left = 1
    composer.startOffsets.right = 0
    composer.leftFootageURL = directory.appending(path: "left.mov")
    composer.rightFootageURL = directory.appending(path: "right.mov")
    // Raw front.mov times; +1 s gives final-video times.
    composer.cameraOverrides = [
        override(.left, 1.5, 2.5, label: "Looking left at the old A303 junction"),
        override(.right, 3.0, 4.0),
    ]
    let output = directory.appending(path: "final.mov")
    try await composer.writeMovie(to: output)

    // Before any window (final 1.6 s, route map gone): the rear view.
    let before = try await frame(of: output, at: 1.6)
    #expect(isClose(try rgb(before, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear")
    let rearLabel = try labelWidth(in: before, tileColour: [0, 0, 255])
    #expect(rearLabel > 60 && rearLabel < 300, "rear label width \(rearLabel)")

    // Mid left window (final 2.5...3.5 s): green - the offset applied, not
    // magenta - with its own, longer label.
    let left = try await frame(of: output, at: 3.0)
    #expect(isClose(try rgb(left, slotMiddle.0, slotMiddle.1), to: [0, 255, 0]), "left in sync")
    let leftLabel = try labelWidth(in: left, tileColour: [0, 255, 0])
    #expect(leftLabel > rearLabel + 200, "left label \(leftLabel) vs rear \(rearLabel)")

    // Halfway through the dissolve into the left view: a blend of both.
    let dissolving = try await frame(of: output, at: 2.65)
    let blend = try rgb(dissolving, slotMiddle.0, slotMiddle.1)
    #expect(blend[1] > 60 && blend[1] < 200 && blend[2] > 60 && blend[2] < 200, "dissolve \(blend)")

    // Between windows, the rear view again; then the right view (final
    // 4...5 s).
    let between = try await frame(of: output, at: 3.75)
    #expect(isClose(try rgb(between, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear again")
    let right = try await frame(of: output, at: 4.5)
    #expect(isClose(try rgb(right, slotMiddle.0, slotMiddle.1), to: [255, 0, 0]), "right")
    #expect(
        abs(try labelWidth(in: right, tileColour: [255, 0, 0]) - rearLabel) < 60,
        "right uses a default-length label")

    // The slot's shadow falls outside it (below/right), not across it.
    #expect(isClose(try rgb(right, 978, 538), to: [255, 0, 0]), "slot's bottom-right corner")
    #expect(!isClose(try rgb(right, 500, 568), to: [204, 204, 204]), "shadow below the slot")
}

@Test(.timeLimit(.minutes(2)))
func withoutOverridesTheSlotShowsTheRearView() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await writeCommonClips(in: directory)

    let output = directory.appending(path: "final.mov")
    try await composer(in: directory).writeMovie(to: output)

    for seconds in [1.6, 3.0, 4.5] {
        let image = try await frame(of: output, at: seconds)
        #expect(isClose(try rgb(image, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "\(seconds)s")
    }
}

@Test(.timeLimit(.minutes(2)))
func invalidCameraOverridesFailTheRender() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await writeCommonClips(in: directory)
    try await writeClip(
        directory.appending(path: "left.mov"), width: 960, height: 540, seconds: 2
    ) { _ in green }

    func failure(_ overrides: [CameraOverride], left: Bool = true) async -> String {
        var composer = composer(in: directory)
        if left {
            composer.startOffsets.left = 0
            composer.leftFootageURL = directory.appending(path: "left.mov")
        }
        composer.cameraOverrides = overrides
        let error = await #expect(throws: (any Error).self) {
            try await composer.writeMovie(to: directory.appending(path: "final.mov"))
        }
        return String(describing: error)
    }

    // The journey has no right camera.
    #expect(await failure([override(.right, 1, 2)]).contains("right_offset"))
    // Two windows overlapping.
    #expect(await failure([override(.left, 1, 1.8), override(.rear, 1.5, 2.5)]).contains("overlaps"))
    // Past the end of left.mov (2 s long).
    #expect(await failure([override(.left, 1.5, 3)]).contains("left.mov"))
    // Ends before it starts.
    #expect(await failure([override(.left, 2, 1)]).contains("ends before it starts"))
}
