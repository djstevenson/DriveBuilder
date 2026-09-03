import AppKit
import CoreGraphics
import Foundation

/// Stacks pre-rasterized layers into a single frame, rotating each about the centre.
///
/// Layers must already be rasterized. Rasterizing inside the compositing context
/// nests `NSGraphicsContext` state and silently discards earlier layers.
enum LayerCompositor {
    struct Layer {
        let image: CGImage

        /// Clockwise rotation about the image centre, matching SVG's `rotate()`.
        var rotationDegrees: Double = 0

        init(_ image: CGImage, rotationDegrees: Double = 0) {
            self.image = image
            self.rotationDegrees = rotationDegrees
        }
    }

    /// Draws `layers` in order into an existing context, clearing it first.
    ///
    /// Contexts are reused across frames, so the clear is required or the
    /// previous frame shows through the transparent regions.
    static func draw(_ layers: [Layer], into context: CGContext, width: Int, height: Int) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        for layer in layers {
            draw(layer, into: context, bounds: bounds)
        }
    }

    static func draw(_ layer: Layer, into context: CGContext, bounds: CGRect) {
        // A rotated draw resamples the whole frame and costs roughly 20x a blit,
        // so unrotated layers skip the transform entirely.
        guard layer.rotationDegrees != 0 else {
            context.draw(layer.image, in: bounds)
            return
        }
        context.saveGState()
        // The context has a bottom-left origin, so positive Core Graphics
        // angles run anticlockwise; negate to keep SVG's clockwise sense.
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: -layer.rotationDegrees * .pi / 180)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.draw(layer.image, in: bounds)
        context.restoreGState()
    }

    /// A standalone image of `image` rotated about its centre.
    ///
    /// Use this to pre-rotate a layer whose angle recurs across many frames, so
    /// the per-frame cost becomes a blit rather than a resample.
    static func rotatedImage(_ image: CGImage, degrees: Double, width: Int, height: Int) throws
        -> CGImage
    {
        let context = try bitmapContext(width: width, height: height)
        draw([Layer(image, rotationDegrees: degrees)], into: context, width: width, height: height)
        guard let rotated = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return rotated
    }

    /// Composites into a fresh bitmap. For stills, rather than the video path.
    static func composite(_ layers: [Layer], width: Int, height: Int) throws -> NSBitmapImageRep {
        let canvas = try SVGRasterizer.blankBitmap(width: width, height: height)
        try SVGRasterizer.withGraphicsContext(over: canvas) { context in
            draw(layers, into: context.cgContext, width: width, height: height)
        }
        return canvas
    }

    /// A width x height image filled solidly with `color`, for use as a
    /// backdrop layer.
    static func solidImage(color: CGColor, width: Int, height: Int) throws -> CGImage {
        let context = try bitmapContext(width: width, height: height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw SVGRasterizerError.contextUnavailable
        }
        return image
    }

    /// A premultiplied BGRA context, matching the pixel format the movie writer wants.
    static func bitmapContext(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0 else {
            throw SVGRasterizerError.invalidSize(width: width, height: height)
        }
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
        else {
            throw SVGRasterizerError.contextUnavailable
        }
        return context
    }
}
