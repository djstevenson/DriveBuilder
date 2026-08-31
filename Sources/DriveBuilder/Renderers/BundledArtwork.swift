import Foundation

enum BundledArtworkError: Error, CustomStringConvertible {
    case missing(name: String, dial: String)

    var description: String {
        switch self {
        case .missing(let name, let dial):
            "Bundled artwork \"\(name).svg\" not found for the \(dial) dial"
        }
    }
}

/// Vector artwork copied into the executable's resource bundle from `Resources/SVG`.
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
}
