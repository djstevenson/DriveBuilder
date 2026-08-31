import Foundation

/// Converts WGS84 latitude/longitude to British National Grid easting/northing,
/// the coordinate system the map tiles are rendered in.
///
/// Uses the OS-published small Helmert transformation (WGS84 cartesian to
/// OSGB36) followed by the Airy 1830 transverse Mercator projection. Accurate
/// to a few metres against OSTN15, and within a metre of the Perl
/// Geo::Coordinates::OSGB values this replaces; at 2 m/pixel both are
/// invisible, and any residual offset applies equally to the tile bounding
/// box and the car position, so it cancels out of the framing.
enum OSGB {
    struct GridPoint: Equatable {
        let easting: Double
        let northing: Double
    }

    /// WGS84 ellipsoid.
    private static let wgsA = 6_378_137.0
    private static let wgsB = 6_356_752.3141

    /// Airy 1830 ellipsoid, used by OSGB36.
    private static let airyA = 6_377_563.396
    private static let airyB = 6_356_256.909

    /// National Grid projection constants: scale on the central meridian,
    /// true origin 49°N 2°W, and the false origin offset in metres.
    private static let f0 = 0.9996012717
    private static let lat0 = 49.0 * .pi / 180
    private static let lon0 = -2.0 * .pi / 180
    private static let e0 = 400_000.0
    private static let n0 = -100_000.0

    static func gridPoint(latitude: Double, longitude: Double) -> GridPoint {
        let osgb36 = toOSGB36(latitudeDegrees: latitude, longitudeDegrees: longitude)
        return project(latitude: osgb36.latitude, longitude: osgb36.longitude)
    }

    /// Datum shift: WGS84 geodetic -> cartesian -> Helmert -> OSGB36 geodetic.
    private static func toOSGB36(latitudeDegrees: Double, longitudeDegrees: Double)
        -> (latitude: Double, longitude: Double)
    {
        let lat = latitudeDegrees * .pi / 180
        let lon = longitudeDegrees * .pi / 180

        // Geodetic to cartesian on WGS84, at ellipsoid height 0.
        let wgsE2 = 1 - (wgsB * wgsB) / (wgsA * wgsA)
        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let nu = wgsA / (1 - wgsE2 * sinLat * sinLat).squareRoot()
        let x = nu * cosLat * cos(lon)
        let y = nu * cosLat * sin(lon)
        let z = nu * (1 - wgsE2) * sinLat

        // OS-published WGS84 -> OSGB36 Helmert parameters: translation in
        // metres, rotation in arcseconds, scale in parts per million.
        let tx = -446.448
        let ty = 125.157
        let tz = -542.060
        let arcsec = Double.pi / 180 / 3600
        let rx = -0.1502 * arcsec
        let ry = -0.2470 * arcsec
        let rz = -0.8421 * arcsec
        let s = 20.4894e-6

        let x2 = tx + (1 + s) * x - rz * y + ry * z
        let y2 = ty + rz * x + (1 + s) * y - rx * z
        let z2 = tz - ry * x + rx * y + (1 + s) * z

        // Cartesian back to geodetic on Airy 1830, iterating the latitude.
        let airyE2 = 1 - (airyB * airyB) / (airyA * airyA)
        let p = (x2 * x2 + y2 * y2).squareRoot()
        var lat2 = atan2(z2, p * (1 - airyE2))
        for _ in 0..<8 {
            let sinLat2 = sin(lat2)
            let nu2 = airyA / (1 - airyE2 * sinLat2 * sinLat2).squareRoot()
            lat2 = atan2(z2 + airyE2 * nu2 * sinLat2, p)
        }
        return (lat2, atan2(y2, x2))
    }

    /// Transverse Mercator projection of OSGB36 geodetic coordinates,
    /// following the formulae in the OS "Guide to coordinate systems".
    private static func project(latitude lat: Double, longitude lon: Double) -> GridPoint {
        let a = airyA
        let b = airyB
        let e2 = 1 - (b * b) / (a * a)
        let n = (a - b) / (a + b)

        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let tanLat = tan(lat)

        let nu = a * f0 / (1 - e2 * sinLat * sinLat).squareRoot()
        let rho = a * f0 * (1 - e2) / pow(1 - e2 * sinLat * sinLat, 1.5)
        let eta2 = nu / rho - 1

        // Meridional arc from the true origin.
        let m =
            b * f0
            * ((1 + n + 5.0 / 4 * n * n + 5.0 / 4 * n * n * n) * (lat - lat0)
                - (3 * n + 3 * n * n + 21.0 / 8 * n * n * n) * sin(lat - lat0) * cos(lat + lat0)
                + (15.0 / 8 * n * n + 15.0 / 8 * n * n * n) * sin(2 * (lat - lat0))
                    * cos(2 * (lat + lat0))
                - 35.0 / 24 * n * n * n * sin(3 * (lat - lat0)) * cos(3 * (lat + lat0)))

        let i = m + n0
        let ii = nu / 2 * sinLat * cosLat
        let iii = nu / 24 * sinLat * pow(cosLat, 3) * (5 - tanLat * tanLat + 9 * eta2)
        let iiia = nu / 720 * sinLat * pow(cosLat, 5)
            * (61 - 58 * tanLat * tanLat + pow(tanLat, 4))
        let iv = nu * cosLat
        let v = nu / 6 * pow(cosLat, 3) * (nu / rho - tanLat * tanLat)
        let vi = nu / 120 * pow(cosLat, 5)
            * (5 - 18 * tanLat * tanLat + pow(tanLat, 4) + 14 * eta2
                - 58 * tanLat * tanLat * eta2)

        let dLon = lon - lon0
        let northing = i + ii * pow(dLon, 2) + iii * pow(dLon, 4) + iiia * pow(dLon, 6)
        let easting = e0 + iv * dLon + v * pow(dLon, 3) + vi * pow(dLon, 5)
        return GridPoint(easting: easting, northing: northing)
    }
}
