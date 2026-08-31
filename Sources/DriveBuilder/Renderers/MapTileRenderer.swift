import CoreGraphics
import Foundation
import ImageIO

/// A map area to render: a British National Grid bounding box in metres and
/// the pixel size of the resulting image.
struct MapBBox: Equatable, Sendable {
    var minEasting: Double
    var minNorthing: Double
    var maxEasting: Double
    var maxNorthing: Double
    var width: Int
    var height: Int
}

extension MapBBox {
    /// Pixel position of a grid point within this box's image, in
    /// top-left-origin coordinates: northing increases going north, but
    /// pixel y increases downward.
    func pixelPosition(of grid: OSGB.GridPoint) -> CGPoint {
        let metresPerPixel = (maxEasting - minEasting) / Double(width)
        return CGPoint(
            x: (grid.easting - minEasting) / metresPerPixel,
            y: (maxNorthing - grid.northing) / metresPerPixel)
    }
}

/// Renders base-map imagery for a bounding box. Injectable so tests can
/// substitute synthetic imagery for the external Mapnik renderer.
protocol MapTileRenderer {
    func renderMap(_ bbox: MapBBox) throws -> CGImage
}

enum MapTileError: Error, CustomStringConvertible {
    case renderFailed(status: Int32)
    case undecodableImage

    var description: String {
        switch self {
        case .renderFailed(let status):
            "maprender.py exited with status \(status)"
        case .undecodableImage:
            "maprender.py output could not be decoded as an image"
        }
    }
}

/// Renders map tiles by running the Perl project's `maprender.py`, a thin
/// Mapnik wrapper over `map.xml` and its local OSM extract, so the Swift
/// port produces identical cartography.
struct MaprenderTileRenderer: MapTileRenderer {
    /// The drive-builder Perl project checkout, containing `maprender.py`,
    /// `map.xml`, and the OSM data they reference.
    let directory: URL

    /// Scales road widths, shields, and text to suit the output size;
    /// 1 renders the stylesheet's pixel sizes as-is.
    var scaleFactor = 1.0

    /// Mapnik stylesheet to render with, relative to `directory`. The
    /// default full-detail sheet suits journey-scale areas; map-national.xml
    /// keeps a country-wide render legible.
    var stylesheet = "map.xml"

    func renderMap(_ bbox: MapBBox) throws -> CGImage {
        let process = Process()
        process.executableURL = directory.appending(path: "maprender.py")
        process.currentDirectoryURL = directory
        process.arguments = [
            String(bbox.minEasting), String(bbox.minNorthing),
            String(bbox.maxEasting), String(bbox.maxNorthing),
            String(bbox.width), String(bbox.height),
            String(scaleFactor),
            "--style", stylesheet,
        ]

        // The script's `env python3` needs the pyenv shim on PATH: that
        // python has the mapnik bindings, the system ones do not.
        var environment = ProcessInfo.processInfo.environment
        let shims = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".pyenv/shims").path(percentEncoded: false)
        environment["PATH"] = "\(shims):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        // stderr is left inherited so Mapnik's progress lines show through.
        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        // Drain stdout before waiting, or a tile PNG bigger than the pipe
        // buffer deadlocks the child.
        let png = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MapTileError.renderFailed(status: process.terminationStatus)
        }
        guard
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else {
            throw MapTileError.undecodableImage
        }
        return image
    }
}
