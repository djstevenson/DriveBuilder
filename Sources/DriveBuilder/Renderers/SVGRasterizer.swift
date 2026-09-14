import AppKit
import Foundation

enum SVGRasterizerError: Error, CustomStringConvertible {
    case invalidSize(width: Int, height: Int)
    case undecodableArtwork
    case contextUnavailable
    case pngEncodingFailed

    var description: String {
        switch self {
        case .invalidSize(let width, let height):
            "Raster size must be positive, got \(width)x\(height)"
        case .undecodableArtwork:
            "Artwork could not be decoded as an image"
        case .contextUnavailable:
            "Could not create a drawing context for the requested size"
        case .pngEncodingFailed:
            "Rasterized image could not be encoded as PNG"
        }
    }
}

/// Rasterizes vector artwork to bitmaps entirely in memory.
///
/// SVG is decoded by AppKit rather than ImageIO: `CGImageSource` has no SVG
/// decoder, but `NSImage` reads `public.svg-image` and rasterizes it as vector
/// geometry at whatever size it is drawn into.
struct SVGRasterizer {
    /// AppKit's `NSGraphicsContext` is thread-affine: it opens a window-server
    /// access session on whichever *OS thread* first uses it and logs
    /// "CGAccessSession cannot be shared between threads" if a later call
    /// arrives from another one. A serial `DispatchQueue` doesn't fix this —
    /// `sync` is free to run its block inline on the calling thread rather
    /// than a dedicated worker, so the session still hops threads. This
    /// dedicated, always-running thread is the only thing that ever touches
    /// `NSGraphicsContext`, so the session's thread never changes.
    private final class GraphicsThread: Thread, @unchecked Sendable {
        private let condition = NSCondition()
        private var pendingWork: [() -> Void] = []

        override func main() {
            while true {
                condition.lock()
                while pendingWork.isEmpty {
                    condition.wait()
                }
                let work = pendingWork.removeFirst()
                condition.unlock()
                work()
            }
        }

        func run<T>(_ body: @escaping () throws -> T) throws -> T {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: Result<T, Error>!
            condition.lock()
            pendingWork.append {
                outcome = Result { try body() }
                semaphore.signal()
            }
            condition.signal()
            condition.unlock()
            semaphore.wait()
            return try outcome.get()
        }
    }

    private static let graphicsThread: GraphicsThread = {
        let thread = GraphicsThread()
        thread.name = "SVGRasterizer.appkit"
        // Callers typically run at user-initiated QoS or above; leaving this
        // thread at the default QoS makes them block on a lower-priority
        // thread, which the Thread Performance Checker flags as a priority
        // inversion.
        thread.qualityOfService = .userInitiated
        thread.start()
        return thread
    }()

    /// Runs `body` with an AppKit graphics context over `canvas`, always on
    /// the same dedicated OS thread, however many renderers rasterize
    /// concurrently.
    static func withGraphicsContext<T>(
        over canvas: NSBitmapImageRep, _ body: @escaping (NSGraphicsContext) throws -> T
    ) throws -> T {
        try graphicsThread.run {
            guard let context = NSGraphicsContext(bitmapImageRep: canvas) else {
                throw SVGRasterizerError.contextUnavailable
            }
            return try body(context)
        }
    }

    /// `artwork` drawn at exactly `width` x `height` pixels, preserving transparency.
    ///
    /// The pixel size is set explicitly because drawing at the image's natural
    /// size follows the current display's backing scale, which would make output
    /// resolution depend on which machine the tool runs on.
    static func bitmap(from artwork: Data, width: Int, height: Int) throws -> NSBitmapImageRep {
        guard let image = NSImage(data: artwork) else {
            throw SVGRasterizerError.undecodableArtwork
        }
        let canvas = try blankBitmap(width: width, height: height)
        try withGraphicsContext(over: canvas) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }

        return canvas
    }

    /// PNG data for `artwork` drawn at exactly `width` x `height` pixels.
    static func png(from artwork: Data, width: Int, height: Int) throws -> Data {
        try png(from: bitmap(from: artwork, width: width, height: height))
    }

    /// PNG data for an already rasterized bitmap.
    static func png(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SVGRasterizerError.pngEncodingFailed
        }
        return png
    }

    /// The bitmap's pixels as a `CGImage` safe to draw from several threads
    /// at once. `NSBitmapImageRep.cgImage` (like ImageIO decoding) returns a
    /// lazily materialized image whose CGAccessSession is tied to the first
    /// thread that draws it; the frame loops draw shared artwork from many
    /// threads, so hand out an eagerly decoded plain-memory copy instead.
    static func cgImage(from bitmap: NSBitmapImageRep) throws -> CGImage {
        guard let image = bitmap.cgImage?.bitmapBackedCopy() else {
            throw SVGRasterizerError.undecodableArtwork
        }
        return image
    }

    /// An empty transparent bitmap sized in pixels rather than points.
    static func blankBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        guard width > 0, height > 0 else {
            throw SVGRasterizerError.invalidSize(width: width, height: height)
        }
        guard
            let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else {
            throw SVGRasterizerError.contextUnavailable
        }
        // Without this the rep reports its size in points, and drawing scales by the display factor.
        canvas.size = NSSize(width: width, height: height)
        return canvas
    }
}

extension CGImage {
    /// A copy backed by plain bitmap memory, decoded eagerly on the calling
    /// thread, so it can safely be drawn from several threads at once.
    func bitmapBackedCopy() -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
