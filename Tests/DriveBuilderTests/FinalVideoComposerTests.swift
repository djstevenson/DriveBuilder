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
/// the drive segment from 1 s to 9 s (raw front.mov 0 s is 1 s in the final
/// video); the outro starts fading in at 8.5 s.
private func writeCommonClips(in directory: URL) async throws {
    func url(_ name: String) -> URL { directory.appending(path: name) }
    try await writeClip(url("intro.mov"), width: 64, height: 36, seconds: 1) { _ in grey }
    try await writeClip(url("outro.mov"), width: 64, height: 36, seconds: 1) { _ in grey }
    try await writeClip(url("route_map.mov"), width: 3840, height: 2160, seconds: 1) { _ in grey }
    try await writeClip(url("dials.mov"), width: 64, height: 196, seconds: 8) { _ in
        CGColor(gray: 0, alpha: 0)
    }
    try await writeClip(url("front.mov"), width: 640, height: 360, seconds: 8) { _ in grey }
    try await writeClip(url("rear.mov"), width: 960, height: 540, seconds: 8) { _ in blue }
}

private func composer(in directory: URL) -> FinalVideoComposer {
    func url(_ name: String) -> URL { directory.appending(path: name) }
    var composer = FinalVideoComposer(
        introURL: url("intro.mov"), routeMapURL: url("route_map.mov"),
        dialsURL: url("dials.mov"), outroURL: url("outro.mov"),
        segments: [.init(frontURL: url("front.mov"), rearURL: url("rear.mov"))])
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
) -> FinalVideoComposer.PlacedCameraOverride {
    FinalVideoComposer.PlacedCameraOverride(
        camera: camera, start: start, end: end, label: label ?? camera.defaultLabel)
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

@Test func slidingTileStaysCroppedToTheSlot() {
    let slot = CGRect(x: 20, y: 20, width: 960, height: 540)
    let size = CGSize(width: 960, height: 540)

    let home = FinalVideoComposer.slidingTile(clipSize: size, slot: slot, offset: 0)
    #expect(home.transform.tx == 20 && home.transform.ty == 20)
    #expect(home.crop == CGRect(x: 0, y: 0, width: 960, height: 540))

    // Halfway out to the right: drawn from x = 500, only its left half kept.
    let right = FinalVideoComposer.slidingTile(clipSize: size, slot: slot, offset: 480)
    #expect(right.transform.tx == 500)
    #expect(right.crop == CGRect(x: 0, y: 0, width: 480, height: 540))

    // Halfway in from the left: drawn from x = -460, only its right half kept.
    let left = FinalVideoComposer.slidingTile(clipSize: size, slot: slot, offset: -480)
    #expect(left.transform.tx == -460)
    #expect(left.crop == CGRect(x: 480, y: 0, width: 480, height: 540))

    // All the way out: a 1-pixel sliver at the slot's edge, never empty.
    let gone = FinalVideoComposer.slidingTile(clipSize: size, slot: slot, offset: 960)
    #expect(gone.crop.width == 1)
}

@Test(.timeLimit(.minutes(2)))
func cameraOverridesPushIntoTheSlotInSyncWithLabels() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await writeCommonClips(in: directory)
    // The left camera started recording 1 s early: magenta for that second,
    // then green once in sync. It's shorter than the journey, which is fine:
    // it only has to cover its window.
    try await writeClip(
        directory.appending(path: "left.mov"), width: 960, height: 540, seconds: 5
    ) { $0 < 30 ? magenta : green }
    try await writeClip(
        directory.appending(path: "right.mov"), width: 960, height: 540, seconds: 8
    ) { _ in red }

    var composer = composer(in: directory)
    composer.segments[0].startOffsets.left = 1
    composer.segments[0].startOffsets.right = 0
    composer.segments[0].leftURL = directory.appending(path: "left.mov")
    composer.segments[0].rightURL = directory.appending(path: "right.mov")
    // Drive seconds; +1 s gives final-video times: left 1.6...4.2 s,
    // right 4.6...7.3 s. Each push takes 1 s; a label pops in over 0.35 s
    // once its push has landed.
    composer.cameraOverrides = [
        override(.left, 0.6, 3.2, label: "Looking left at the old A303 junction"),
        override(.right, 3.6, 6.3),
    ]
    let output = directory.appending(path: "final.mov")
    try await composer.writeMovie(to: output)

    // Before any window (route map gone at 1.5 s): the rear view, labelled.
    let before = try await frame(of: output, at: 1.55)
    #expect(isClose(try rgb(before, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear")
    let rearLabel = try labelWidth(in: before, tileColour: [0, 0, 255])
    #expect(rearLabel > 60 && rearLabel < 300, "rear label width \(rearLabel)")

    // Halfway through the left camera's push (eased to halfway too): it
    // fills the slot's left half, the rear view pushed into the right half.
    // No label while the push is under way.
    let pushing = try await frame(of: output, at: 2.1)
    #expect(isClose(try rgb(pushing, 200, 290), to: [0, 255, 0]), "left arriving from the left")
    #expect(isClose(try rgb(pushing, 800, 290), to: [0, 0, 255]), "rear leaving to the right")
    #expect(isClose(try rgb(pushing, 30, 46), to: [0, 255, 0]), "no label mid-push")

    // Landed, label popped (by 2.95 s; the push out starts at 3.2 s): green -
    // the offset applied, not magenta - with its own, longer label.
    let left = try await frame(of: output, at: 3.05)
    #expect(isClose(try rgb(left, slotMiddle.0, slotMiddle.1), to: [0, 255, 0]), "left in sync")
    let leftLabel = try labelWidth(in: left, tileColour: [0, 255, 0])
    #expect(leftLabel > rearLabel + 200, "left label \(leftLabel) vs rear \(rearLabel)")

    // Between the windows: the rear view back, but no label - the next
    // window follows too closely for it to pop in and out again.
    let between = try await frame(of: output, at: 4.4)
    #expect(isClose(try rgb(between, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear again")
    #expect(isClose(try rgb(between, 30, 46), to: [0, 0, 255]), "rear label stays away")

    // The right camera arrives from the right, pushing the rear view left.
    let rightPushing = try await frame(of: output, at: 5.1)
    #expect(isClose(try rgb(rightPushing, 200, 290), to: [0, 0, 255]), "rear leaving to the left")
    #expect(isClose(try rgb(rightPushing, 800, 290), to: [255, 0, 0]), "right arriving from the right")

    let right = try await frame(of: output, at: 6.1)
    #expect(isClose(try rgb(right, slotMiddle.0, slotMiddle.1), to: [255, 0, 0]), "right")
    #expect(
        abs(try labelWidth(in: right, tileColour: [255, 0, 0]) - rearLabel) < 60,
        "right uses a default-length label")

    // Nothing spills outside the slot mid-push, and its shadow falls
    // outside it (below/right), not across it.
    #expect(isClose(try rgb(right, 978, 538), to: [255, 0, 0]), "slot's bottom-right corner")
    #expect(!isClose(try rgb(right, 500, 568), to: [204, 204, 204]), "shadow below the slot")
    #expect(isClose(try rgb(rightPushing, 1100, 290), to: [204, 204, 204]), "nothing beyond the slot")
    #expect(isClose(try rgb(pushing, 10, 290), to: [204, 204, 204]), "nothing left of the slot")

    // After the right window, the rear view and its label come back.
    let after = try await frame(of: output, at: 8.0)
    #expect(isClose(try rgb(after, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear after")
    #expect(try labelWidth(in: after, tileColour: [0, 0, 255]) > 60, "rear label back")
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

    func failure(
        _ overrides: [FinalVideoComposer.PlacedCameraOverride], left: Bool = true
    ) async -> String {
        var composer = composer(in: directory)
        if left {
            composer.segments[0].startOffsets.left = 0
            composer.segments[0].leftURL = directory.appending(path: "left.mov")
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
    #expect(await failure([override(.left, 0.5, 3.5)]).contains("left.mov"))
    // Ends before it starts.
    #expect(await failure([override(.left, 2, 1)]).contains("ends before it starts"))
}

// MARK: - Segments

private let yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
private let cyan = CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

/// A point on the drive footage clear of the camera slot and dial column.
private let backdrop = (2000, 1500)

/// Two segments over the common clips: 3 s of grey front.mov, then
/// front-2.mov from 1 s in (magenta for its first second, then yellow), with
/// the rear camera left running: rear.mov blue for 4 s, then cyan, the
/// second segment picking it up 4 s in. The second runs for its shortest
/// source, 4 s, so the drive is final 1...8 s with the join at 4 s.
private func twoSegmentComposer(in directory: URL) async throws -> FinalVideoComposer {
    try await writeCommonClips(in: directory)
    try await writeClip(
        directory.appending(path: "rear.mov"), width: 960, height: 540, seconds: 8
    ) { $0 < 120 ? blue : cyan }
    try await writeClip(
        directory.appending(path: "front-2.mov"), width: 640, height: 360, seconds: 5
    ) { $0 < 30 ? magenta : yellow }

    var composer = composer(in: directory)
    composer.segments[0].length = 3
    var second = FinalVideoComposer.SegmentFootage(
        frontURL: directory.appending(path: "front-2.mov"),
        rearURL: directory.appending(path: "rear.mov"))
    second.startOffsets.front = 1
    second.startOffsets.rear = 4
    composer.segments.append(second)
    return composer
}

@Test(.timeLimit(.minutes(2)))
func segmentsPlayInTurnDippingToBlackAtTheJoin() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "final.mov")
    try await twoSegmentComposer(in: directory).writeMovie(to: output)

    // The outro starts fading in half a second before the drive ends at 8 s.
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(abs(duration - 8.5) < 0.05, "duration \(duration)")

    // The first segment: grey footage, the rear view from rear.mov's start.
    let first = try await frame(of: output, at: 3.0)
    #expect(isClose(try rgb(first, backdrop.0, backdrop.1), to: [204, 204, 204]), "front.mov")
    #expect(isClose(try rgb(first, slotMiddle.0, slotMiddle.1), to: [0, 0, 255]), "rear.mov early")

    // Halfway down into the join, and black at it.
    let dipping = try await frame(of: output, at: 3.75)
    #expect(isClose(try rgb(dipping, backdrop.0, backdrop.1), to: [102, 102, 102]), "fading out")
    let join = try await frame(of: output, at: 4.0)
    #expect(isClose(try rgb(join, backdrop.0, backdrop.1), to: [0, 0, 0]), "black at the join")
    #expect(isClose(try rgb(join, slotMiddle.0, slotMiddle.1), to: [0, 0, 0]), "slot black too")

    // The second segment: front-2.mov past its skipped magenta second, and
    // the rear view picked up 4 s into rear.mov.
    let second = try await frame(of: output, at: 5.5)
    #expect(isClose(try rgb(second, backdrop.0, backdrop.1), to: [255, 255, 0]), "front-2.mov")
    #expect(isClose(try rgb(second, slotMiddle.0, slotMiddle.1), to: [0, 255, 255]), "rear.mov later")
    let fadingIn = try await frame(of: output, at: 4.6)
    #expect(isClose(try rgb(fadingIn, backdrop.0, backdrop.1), to: [255, 255, 0]), "not magenta")
}

@Test(.timeLimit(.minutes(2)))
func aCappedRenderOnlyPlacesTheSegmentsBeforeTheCap() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var composer = try await twoSegmentComposer(in: directory)
    // A quick preview's dials.mov: rendered only for the start of the drive,
    // so it doesn't reach the second segment, which isn't even loaded.
    try await writeClip(
        directory.appending(path: "dials.mov"), width: 64, height: 196, seconds: 2
    ) { _ in CGColor(gray: 0, alpha: 0) }
    composer.segments[1].frontURL = directory.appending(path: "missing.mov")
    composer.maxDriveSegmentSeconds = 2

    let output = directory.appending(path: "final.mov")
    try await composer.writeMovie(to: output)

    // The drive runs 1...3 s, then the outro fades in for its 1 s.
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(abs(duration - 3.5) < 0.05, "duration \(duration)")
}

@Test(.timeLimit(.minutes(2)))
func aCappedRenderStopsWhereAShortPreviewDialsMovieDoes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var composer = try await twoSegmentComposer(in: directory)
    // A quick preview's dials.mov covering less than the cap.
    try await writeClip(
        directory.appending(path: "dials.mov"), width: 64, height: 196, seconds: 2
    ) { _ in CGColor(gray: 0, alpha: 0) }
    composer.maxDriveSegmentSeconds = 30

    let output = directory.appending(path: "final.mov")
    try await composer.writeMovie(to: output)

    // The drive stops with dials.mov at 3 s, then the outro fades in.
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(abs(duration - 3.5) < 0.05, "duration \(duration)")
}

@Test(.timeLimit(.minutes(2)))
func segmentsThatCantBeJoinedFailTheRender() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try await twoSegmentComposer(in: directory)
    try await writeClip(
        directory.appending(path: "small-rear.mov"), width: 480, height: 270, seconds: 8
    ) { _ in blue }

    func failure(_ change: (inout FinalVideoComposer) -> Void) async -> String {
        var composer = base
        change(&composer)
        let error = await #expect(throws: (any Error).self) {
            try await composer.writeMovie(to: directory.appending(path: "final.mov"))
        }
        return String(describing: error)
    }

    // Only the last segment may leave its length to its sources.
    #expect(await failure { $0.segments[0].length = nil }.contains("has no length"))
    // Too close to the route map for the join's fade out.
    #expect(await failure { $0.segments[0].length = 0.6 }.contains("too soon"))
    // A camera override across the join.
    #expect(
        await failure { $0.cameraOverrides = [override(.rear, 1, 4.5)] }
            .contains("across the join"))
    // A side camera the second segment doesn't have.
    #expect(
        await failure {
            $0.segments[0].startOffsets.left = 0
            $0.segments[0].leftURL = directory.appending(path: "front.mov")
            $0.cameraOverrides = [override(.left, 3.5, 6.5)]
        }.contains("left_offset"))
    // A rear view of a different size.
    #expect(
        await failure { $0.segments[1].rearURL = directory.appending(path: "small-rear.mov") }
            .contains("same size"))
}
