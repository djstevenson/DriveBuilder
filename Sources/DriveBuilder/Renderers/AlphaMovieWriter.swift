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
struct AlphaMovieWriter {
    let url: URL
    let width: Int
    let height: Int
    let framesPerSecond: Int32

    /// How many frames to composite at once. Compositing dominates the runtime
    /// and frames are independent, so this is the main throughput lever.
    var concurrency: Int = ProcessInfo.processInfo.activeProcessorCount

    /// Renders `frameCount` frames into the movie.
    ///
    /// `drawFrame` is handed a frame index and a cleared context to draw into,
    /// and is called concurrently from several threads with a distinct context
    /// each. It must not touch shared mutable state. Frames are still appended
    /// in index order.
    func write(
        frameCount: Int,
        progress: (Int) -> Void = { _ in },
        drawFrame: (Int, CGContext) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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

        let batchSize = max(1, concurrency)

        // Composites the batch of frames starting at `first` into freshly
        // allocated buffers, in parallel. Each iteration writes only to its
        // own buffer and `concurrentPerform` joins before returning, so the
        // unsafe opt-outs below never actually share mutable state:
        // CVPixelBuffer and the caller's closure aren't Sendable, but each
        // buffer is touched by exactly one iteration, and `drawFrame`'s
        // contract (documented above) requires it to tolerate concurrent
        // calls with distinct contexts.
        nonisolated(unsafe) let draw = drawFrame
        nonisolated(unsafe) let bufferPool = pool
        @Sendable func renderBatch(from first: Int) throws -> FrameBatch {
            let count = min(batchSize, frameCount - first)

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
        var current = frameCount > 0 ? try renderBatch(from: 0) : nil
        while let batch = current {
            let nextIndex = batch.firstIndex + batch.buffers.count
            async let next: FrameBatch? =
                nextIndex < frameCount ? try renderBatch(from: nextIndex) : nil

            // Append in order.
            for (slot, buffer) in batch.buffers.enumerated() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let time = CMTime(
                    value: CMTimeValue(batch.firstIndex + slot), timescale: framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw AlphaMovieWriterError.appendFailed(
                        frameIndex: batch.firstIndex + slot,
                        reason: writer.error?.localizedDescription ?? "unknown error")
                }
                progress(batch.firstIndex + slot + 1)
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
