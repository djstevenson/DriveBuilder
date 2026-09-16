import CoreGraphics
import Foundation
import ImageIO

enum BundledArtworkError: Error, CustomStringConvertible {
    case missing(name: String, dial: String)
    case missingImage(name: String)

    var description: String {
        switch self {
        case .missing(let name, let dial):
            "Bundled artwork \"\(name).svg\" not found for the \(dial) dial"
        case .missingImage(let name):
            "Bundled image \"\(name).jpg\" not found or not decodable"
        }
    }
}

/// Artwork copied into the executable's resource bundle: vector art from
/// `Resources/SVG` and bitmap art from `Resources/Images`.
///
/// The bundle sits beside the executable, so the binary is not self-contained:
/// moving it without its `.bundle` breaks artwork loading.
enum BundledArtwork {
    /// The contents of `SVG/<dial>/<name>.svg`.
    static func svg(_ name: String, dial: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "svg", subdirectory: "SVG/\(dial)")
        else {
            throw BundledArtworkError.missing(name: name, dial: dial)
        }
        return try Data(contentsOf: url)
    }

    /// The image `Images/<name>.jpg`, decoded and ready to draw.
    static func image(_ name: String) throws -> CGImage {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "jpg", subdirectory: "Images"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BundledArtworkError.missingImage(name: name)
        }
        return image
    }
}
