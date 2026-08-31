import CoreGraphics
import Foundation

/// The car marker shared by the progress maps: rasterization of
/// `SVG/progress_map/car.svg` and drawing it rotated at a map position.
enum CarMarker {
    /// The marker rasterized at the same 140px-per-420 scale the Perl
    /// renders `car.svg`, pointing north.
    static func image(scaledFor pixelSize: Int) throws -> CGImage {
        let size = max(140 * pixelSize / 420, 1)
        let bitmap = try SVGRasterizer.bitmap(
            from: BundledArtwork.svg("car", dial: "progress_map"),
            width: size,
            height: size)
        guard let image = bitmap.cgImage else {
            throw SVGRasterizerError.undecodableArtwork
        }
        return image
    }

    /// Draws the marker centred on `position` (top-left-origin frame
    /// coordinates), rotated clockwise by `headingDegrees` about its centre.
    static func draw(
        _ car: CGImage,
        at position: CGPoint,
        headingDegrees: Double,
        into context: CGContext,
        frameHeight: Int
    ) {
        context.saveGState()
        // The context has a bottom-left origin and its positive angles run
        // anticlockwise; flip y and negate to keep the heading's clockwise,
        // top-left-origin sense.
        context.translateBy(x: position.x, y: Double(frameHeight) - position.y)
        context.rotate(by: -headingDegrees * .pi / 180)
        let width = Double(car.width)
        let height = Double(car.height)
        context.draw(
            car, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        context.restoreGState()
    }
}
