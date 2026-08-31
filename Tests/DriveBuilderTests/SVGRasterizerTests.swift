import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private let circleSVG = Data(
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\
    <circle cx="50" cy="50" r="40" fill="red"/></svg>
    """.utf8)

@Test func rasterizesAtRequestedPixelSize() throws {
    let png = try SVGRasterizer.png(from: circleSVG, width: 512, height: 256)
    let decoded = try #require(NSBitmapImageRep(data: png))
    #expect(decoded.pixelsWide == 512)
    #expect(decoded.pixelsHigh == 256)
    #expect(decoded.hasAlpha)
}

@Test func preservesTransparentBackground() throws {
    let png = try SVGRasterizer.png(from: circleSVG, width: 100, height: 100)
    let decoded = try #require(NSBitmapImageRep(data: png))
    let corner = try #require(decoded.colorAt(x: 1, y: 1))
    #expect(corner.alphaComponent < 0.01)
}

@Test(arguments: [(0, 10), (10, 0), (-1, 10)])
func rejectsNonPositiveSizes(width: Int, height: Int) {
    #expect(throws: SVGRasterizerError.self) {
        try SVGRasterizer.png(from: circleSVG, width: width, height: height)
    }
}

@Test func rejectsArtworkThatIsNotAnImage() {
    #expect(throws: SVGRasterizerError.self) {
        try SVGRasterizer.png(from: Data("not an image".utf8), width: 10, height: 10)
    }
}
