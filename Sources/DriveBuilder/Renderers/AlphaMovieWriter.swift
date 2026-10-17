import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import VideoToolbox

enum AlphaMovieWriterError: Error, CustomStringConvertible {
    case cannotAddInput
    case startFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(CVReturn)
    case contextCreationFailed
    case appendFailed(frameIndex: Int, reason: String)
    case finishFailed(String)
    case joinFailed(String)

    var description: String {
        switch self {
        case .cannotAddInput:
            "The asset writer rejected the video input"
        case .startFailed(let reason):
            "Could not start writing the movie: \(reason)"
        case .pixelBufferPoolUnavailable:
            "No pixel buffer pool; the writing session did not start"
        case .pixelBufferAllocationFailed(let status):
            "Could not allocate a pixel buffer from the pool (CVReturn \(status))"
        case .contextCreationFailed:
            "Could not create a drawing context over the pixel buffer"
        case .appendFailed(let frameIndex, let reason):
            "Failed to append frame \(frameIndex): \(reason)"
        case .finishFailed(let reason):
            "Could not finish writing the movie: \(reason)"
        case .joinFailed(let reason):
            "Could not join the movie's segments: \(reason)"
        }
    }
}

/// One composited batch handed from the drawing task to the append loop.
/// `@unchecked Sendable` because ownership transfers wholesale: the drawing
/// task is done with every buffer before the batch is returned, and only
/// the append loop touches them afterwards.
private struct FrameBatch: @unchecked Sendable {
    let firstIndex: Int
    let buffers: [CVPixelBuffer]
}

/// Writes a sequence of frames to a QuickTime movie as ProRes 4444,
/// which is the only widely supported codec that keeps an alpha channel.
///
/// The AVFoundation equivalent of piping raw BGRA into `ffmpeg -c:v prores_ks
/// -profile:v 4 -pix_fmt yuva444p10le`.
///
/// A single writer session is the bottleneck: drawing runs ~4x faster than
/// one hardware ProRes encoder takes frames, and the M1 Ultra has four
/// ProRes engines. So long movies are cut into `framesPerChunk`-frame
/// chunks, encoded `writerCount` at a time by separate writers into
/// temporary files on the internal disk. Meanwhile a joiner copies each
/// finished chunk's compressed samples, in order and without re-encoding,
/// into `url`, deleting the chunk once it's been copied. Joining overlaps
/// encoding, so the destination disk is written while the encoders work
/// rather than in one long copy at the end.
struct AlphaMovieWriter {
    let url: URL
    let width: Int
    let height: Int
    let framesPerSecond: Int32

    /// How many frames to composite at once, shared across the writers.
    /// Compositing and encoding are pipelined, so this keeps every core busy
    /// while the encoders drain the previous batch.
    var concurrency: Int = ProcessInfo.processInfo.activeProcessorCount

    /// How many writers encode concurrently. Measured on the M1 Ultra
    /// (2026-10-17) rendering real dials frames: 1 writer ~415 fps, 4
    /// writers ~785 fps.
    var writerCount = 4

    /// Frames per chunk: 30 s at 30 fps, about 1 GB of 708x2160 dials.
    /// Movies no longer than one chunk are written directly by a single
    /// writer, with no temporary files.
    var framesPerChunk = 900

    /// Renders `frameCount` frames into the movie.
    ///
    /// `drawFrame` is handed a frame index and a cleared context to draw into,
    /// and is called concurrently from several threads with a distinct context
    /// each. It must not touch shared mutable state. `progress` is called with
    /// the number of frames encoded so far, one call at a time, though not
    /// necessarily from the same thread.
    func write(
        frameCount: Int,
        progress: @escaping (Int) -> Void = { _ in },
        drawFrame: @escaping (Int, CGContext) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }

        let chunks = chunkRanges(frameCount: frameCount)
        let writers = min(writerCount, chunks.count)

        // `drawFrame` and `progress` aren't Sendable, but drawing's contract
        // (above) requires tolerating concurrent calls with distinct
        // contexts, and progress calls are serialised by the lock below.
        nonisolated(unsafe) let draw = drawFrame
        nonisolated(unsafe) let report = progress
        let framesDone = Mutex(0)
        let frameEncoded: @Sendable () -> Void = {
            framesDone.withLock { done in
                done += 1
                report(done)
            }
        }
        // The writers share the batch width, so memory use (two batches of
        // buffers in flight per writer) stays as it is with a single writer.
        let batchSize = max(1, concurrency / max(1, writers))

        guard chunks.count > 1 else {
            try await writeSegment(
                frames: 0..<frameCount, to: url, batchSize: batchSize,
                drawFrame: draw, frameEncoded: frameEncoded)
            return
        }

        let chunkDirectory = FileManager.default.temporaryDirectory
            .appending(path: "AlphaMovieWriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: chunkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDirectory) }
        let chunkURLs = chunks.indices.map { chunkDirectory.appending(path: "chunk-\($0).mov") }

        // Writers take chunks in index order, so the joiner is never waiting
        // on a chunk nobody has started.
        let nextChunk = Mutex(0)
        let (finishedChunks, chunkFinished) = AsyncStream.makeStream(of: Int.self)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Ends the stream however the writers finish, so the
                    // joiner can't wait forever on a chunk that failed.
                    defer { chunkFinished.finish() }
                    try await withThrowingTaskGroup(of: Void.self) { writerGroup in
                        for _ in 0..<writers {
                            writerGroup.addTask {
                                while true {
                                    let index = nextChunk.withLock { next in
                                        defer { next += 1 }
                                        return next
                                    }
                                    guard index < chunks.count else { return }
                                    try await writeSegment(
                                        frames: chunks[index], to: chunkURLs[index],
                                        batchSize: batchSize, drawFrame: draw,
                                        frameEncoded: frameEncoded)
                                    chunkFinished.yield(index)
                                }
                            }
                        }
                        try await writerGroup.waitForAll()
                    }
                }
                group.addTask {
                    var joiner: ChunkJoiner?
                    var ready = Set<Int>()
                    var nextToJoin = 0
                    for await index in finishedChunks {
                        ready.insert(index)
                        while ready.remove(nextToJoin) != nil {
                            let chunkURL = chunkURLs[nextToJoin]
                            if joiner == nil {
                                joiner = try await ChunkJoiner(
                                    url: url, firstChunk: chunkURL,
                                    framesPerSecond: framesPerSecond)
                            }
                            try await joiner?.append(chunkURL)
                            try? FileManager.default.removeItem(at: chunkURL)
                            nextToJoin += 1
                        }
                    }
                    // The stream also ends when a writer fails; only a
                    // complete set of chunks makes a finished movie.
                    guard nextToJoin == chunks.count else {
                        try Task.checkCancellation()
                        throw AlphaMovieWriterError.joinFailed(
                            "only \(nextToJoin) of \(chunks.count) chunks were written")
                    }
                    try await joiner?.finish()
                }
                try await group.waitForAll()
            }
        } catch {
            // Don't leave a truncated movie where a finished one is expected.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Consecutive `framesPerChunk`-frame ranges covering `0..<frameCount`;
    /// the last takes whatever remains.
    func chunkRanges(frameCount: Int) -> [Range<Int>] {
        let size = max(1, framesPerChunk)
        guard frameCount > size else { return [0..<frameCount] }
        return stride(from: 0, to: frameCount, by: size).map {
            $0..<min($0 + size, frameCount)
        }
    }

    /// Draws and encodes `frames` into its own movie at `segmentURL`, timed
    /// from zero: a chunk, or the whole movie when it's a single chunk.
    private func writeSegment(
        frames: Range<Int>, to segmentURL: URL, batchSize: Int,
        drawFrame draw: @escaping (Int, CGContext) -> Void,
        frameEncoded: @Sendable () -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: segmentURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // Core Graphics can only produce premultiplied alpha, so the
                    // file has to say so; the encoder otherwise tags it straight
                    // and semi-transparent edges composite too dark downstream.
                    kVTCompressionPropertyKey_AlphaChannelMode as String:
                        kVTAlphaChannelMode_PremultipliedAlpha
                ],
            ])
        // Offline encoding: let the writer apply back pressure rather than drop frames.
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.canAdd(input) else { throw AlphaMovieWriterError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw AlphaMovieWriterError.startFailed(
                writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw AlphaMovieWriterError.pixelBufferPoolUnavailable
        }

        // Composites the batch of frames starting at `first` into freshly
        // allocated buffers, in parallel. Each iteration writes only to its
        // own buffer and `concurrentPerform` joins before returning, so the
        // unsafe opt-outs below never actually share mutable state:
        // CVPixelBuffer and the caller's closure aren't Sendable, but each
        // buffer is touched by exactly one iteration, and `drawFrame`'s
        // contract (documented above) requires it to tolerate concurrent
        // calls with distinct contexts.
        nonisolated(unsafe) let draw = draw
        nonisolated(unsafe) let bufferPool = pool
        @Sendable func renderBatch(from first: Int) throws -> FrameBatch {
            let count = min(batchSize, frames.upperBound - first)

            // Allocate the whole batch up front so each worker owns one buffer.
            var batch: [CVPixelBuffer] = []
            batch.reserveCapacity(count)
            for _ in 0..<count {
                var buffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &buffer)
                guard status == kCVReturnSuccess, let buffer else {
                    throw AlphaMovieWriterError.pixelBufferAllocationFailed(status)
                }
                batch.append(buffer)
            }

            nonisolated(unsafe) let buffers = batch
            let failure = Mutex<(any Error)?>(nil)
            DispatchQueue.concurrentPerform(iterations: count) { slot in
                do {
                    try Self.withContext(over: buffers[slot]) { context in
                        draw(first + slot, context)
                    }
                } catch {
                    failure.withLock { $0 = $0 ?? error }
                }
            }
            if let failure = failure.withLock({ $0 }) { throw failure }
            return FrameBatch(firstIndex: first, buffers: batch)
        }

        // Compositing and appending are pipelined: while one batch feeds the
        // (mostly encoder-bound) append loop, the next is already being
        // drawn, at the cost of keeping two batches of buffers alive.
        var current = frames.isEmpty ? nil : try renderBatch(from: frames.lowerBound)
        while let batch = current {
            // Let a front end's Cancel button take effect between batches.
            try Task.checkCancellation()
            let nextIndex = batch.firstIndex + batch.buffers.count
            async let next: FrameBatch? =
                nextIndex < frames.upperBound ? try renderBatch(from: nextIndex) : nil

            // Append in order, timed from the segment's own start.
            for (slot, buffer) in batch.buffers.enumerated() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let time = CMTime(
                    value: CMTimeValue(batch.firstIndex + slot - frames.lowerBound),
                    timescale: framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw AlphaMovieWriterError.appendFailed(
                        frameIndex: batch.firstIndex + slot,
                        reason: writer.error?.localizedDescription ?? "unknown error")
                }
                frameEncoded()
            }

            current = try await next
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw AlphaMovieWriterError.finishFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Runs `body` with a premultiplied BGRA context drawing straight into `buffer`.
    ///
    /// Compositing into the pixel buffer avoids the intermediate bitmap and the
    /// extra full-frame blit that copying an image in would cost.
    private static func withContext(
        over buffer: CVPixelBuffer,
        _ body: (CGContext) -> Void
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw AlphaMovieWriterError.contextCreationFailed
        }
        body(context)
    }
}

/// Concatenates chunk movies into one by copying their compressed samples,
/// retimed to run on one after another. Nothing is re-encoded, and the
/// first chunk's format description (which carries the premultiplied-alpha
/// tag) describes the whole track. Used from a single task at a time.
private final class ChunkJoiner {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let frameDuration: CMTime
    private var frameIndex: CMTimeValue = 0

    init(url: URL, firstChunk: URL, framesPerSecond: Int32) async throws {
        let firstTrack = try await Self.videoTrack(of: AVURLAsset(url: firstChunk))
        guard let format = try await firstTrack.load(.formatDescriptions).first else {
            throw AlphaMovieWriterError.joinFailed("the first chunk has no format description")
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        frameDuration = CMTime(value: 1, timescale: framesPerSecond)
        guard writer.canAdd(input) else { throw AlphaMovieWriterError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw AlphaMovieWriterError.startFailed(
                writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Copies every frame of `chunk` onto the end of the movie.
    func append(_ chunk: URL) async throws {
        // The reader and its track output must share one asset instance.
        let asset = AVURLAsset(url: chunk)
        let track = try await Self.videoTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AlphaMovieWriterError.joinFailed(
                reader.error?.localizedDescription ?? "could not read \(chunk.lastPathComponent)")
        }

        while let sample = output.copyNextSampleBuffer() {
            // Every sample is one whole frame (ProRes is intra-only).
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            var timing = CMSampleTimingInfo(
                duration: frameDuration,
                presentationTimeStamp: CMTime(value: frameIndex, timescale: frameDuration.timescale),
                decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &retimed)
            guard status == noErr, let retimed else {
                throw AlphaMovieWriterError.joinFailed("could not retime frame \(frameIndex)")
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.append(retimed) else {
                throw AlphaMovieWriterError.appendFailed(
                    frameIndex: Int(frameIndex),
                    reason: writer.error?.localizedDescription ?? "unknown error")
            }
            frameIndex += 1
        }
        if reader.status == .failed {
            throw AlphaMovieWriterError.joinFailed(
                reader.error?.localizedDescription ?? "reading \(chunk.lastPathComponent) failed")
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw AlphaMovieWriterError.finishFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    private static func videoTrack(of asset: AVURLAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AlphaMovieWriterError.joinFailed("no video track in \(asset.url.lastPathComponent)")
        }
        return track
    }
}
