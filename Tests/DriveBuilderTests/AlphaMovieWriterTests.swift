import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import DriveBuilder

/// Frame `index` is a solid colour that encodes its index, with a
/// half-transparent white square in one corner to check alpha survives.
private func drawNumberedFrame(_ index: Int, into context: CGContext, width: Int, height: Int) {
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(
        CGColor(srgbRed: Double(5 * index) / 255, green: Double(255 - 5 * index) / 255, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
}

/// Every frame of the movie at `url`, decoded to BGRA: its presentation
/// time, a pixel from the solid area, and one from the half-transparent
/// corner (bottom-left in drawing coordinates, so the last rows in memory).
private func decodedFrames(
    of url: URL
) async throws -> [(time: CMTime, solid: [UInt8], corner: [UInt8])] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    #expect(reader.startReading())

    var frames: [(time: CMTime, solid: [UInt8], corner: [UInt8])] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        func pixel(x: Int, row: Int) -> [UInt8] {
            (0..<4).map { base[row * bytesPerRow + x * 4 + $0] }
        }
        frames.append(
            (CMSampleBufferGetPresentationTimeStamp(sample),
             pixel(x: 40, row: 10), pixel(x: 8, row: height - 8)))
    }
    #expect(reader.status == .completed)
    return frames
}

@Test func chunkRangesAreContiguousFixedSizeChunks() {
    var writer = AlphaMovieWriter(
        url: URL(filePath: "/dev/null"), width: 8, height: 8, framesPerSecond: 30)
    writer.framesPerChunk = 900

    let chunks = writer.chunkRanges(frameCount: 86_400)
    #expect(chunks.count == 96)
    #expect(chunks.allSatisfy { $0.count == 900 })
    #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect(chunks.first?.lowerBound == 0 && chunks.last?.upperBound == 86_400)
    // The last chunk takes the remainder.
    #expect(writer.chunkRanges(frameCount: 2_000) == [0..<900, 900..<1_800, 1_800..<2_000])
    // One chunk or less: written directly, no split.
    #expect(writer.chunkRanges(frameCount: 900) == [0..<900])
    #expect(writer.chunkRanges(frameCount: 0) == [0..<0])
}

@Test func chunkedWriteJoinsChunksIntoOneFrameExactMovie() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "alpha-movie-writer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let width = 64
    let height = 48
    let frameCount = 45
    func writeMovie(writerCount: Int, framesPerChunk: Int, name: String) async throws -> URL {
        let url = directory.appending(path: name)
        var writer = AlphaMovieWriter(url: url, width: width, height: height, framesPerSecond: 30)
        writer.writerCount = writerCount
        writer.framesPerChunk = framesPerChunk
        let reported = Mutex<[Int]>([])
        try await writer.write(
            frameCount: frameCount,
            progress: { done in reported.withLock { $0.append(done) } },
            drawFrame: { index, context in
                drawNumberedFrame(index, into: context, width: width, height: height)
            })
        // Progress counts every frame exactly once, in order, across writers.
        #expect(reported.withLock { $0 } == Array(1...frameCount))
        return url
    }

    // One chunk: written directly by a single writer, as before chunking.
    let single = try await writeMovie(writerCount: 1, framesPerChunk: 1_000, name: "single.mov")
    // Five chunks across four writers, so the joiner has to wait on chunks
    // finishing out of order.
    let split = try await writeMovie(writerCount: 4, framesPerChunk: 10, name: "split.mov")

    let splitFrames = try await decodedFrames(of: split)
    let singleFrames = try await decodedFrames(of: single)
    #expect(splitFrames.count == frameCount)
    for (index, frame) in splitFrames.enumerated() {
        #expect(frame.time == CMTime(value: CMTimeValue(index), timescale: 30))
        #expect(frame.solid[3] == 255)
    }
    // BGRA: red carries the index. The encoder's colour conversion
    // compresses the range (0, 5, 10... decodes as roughly 20, 24, 29...),
    // so check the step between frames: a repeated frame at a chunk
    // boundary would step by 0, a dropped one by about twice the norm.
    for (previous, frame) in zip(splitFrames, splitFrames.dropFirst()) {
        let step = Int(frame.solid[2]) - Int(previous.solid[2])
        #expect((3...6).contains(step), "red stepped by \(step) at \(frame.time.seconds)s")
    }

    // The joined movie decodes identically to a single-writer one,
    // including the half-transparent corner (premultiplied-alpha tag kept).
    #expect(singleFrames.count == frameCount)
    for (split, single) in zip(splitFrames, singleFrames) {
        #expect(split.solid == single.solid)
        #expect(split.corner == single.corner)
    }
    let corner = try #require(splitFrames.first?.corner)
    #expect(abs(Int(corner[3]) - 128) <= 3, "corner alpha \(corner[3])")
    #expect(abs(Int(corner[2]) - 128) <= 4, "corner premultiplied red \(corner[2])")

    let splitTrack = try #require(
        try await AVURLAsset(url: split).loadTracks(withMediaType: .video).first)
    let singleTrack = try #require(
        try await AVURLAsset(url: single).loadTracks(withMediaType: .video).first)
    let splitFormats = try await splitTrack.load(.formatDescriptions)
    let singleFormats = try await singleTrack.load(.formatDescriptions)
    #expect(splitFormats.count == 1)
    #expect(splitFormats.first?.mediaSubType == singleFormats.first?.mediaSubType)
    #expect(try await splitTrack.load(.timeRange).duration == CMTime(value: 45, timescale: 30))
}
