import Foundation

/// Deriving a running total distance from consecutive GPS fixes.
extension TelemetrySample {
    /// Mean radius of the Earth, in metres.
    private static let earthRadiusMetres = 6_371_000.0

    /// Great-circle distance between two points, in metres, via the
    /// haversine formula.
    static func haversineMetres(
        latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double
    ) -> Double {
        let φ1 = latitude1 * .pi / 180
        let φ2 = latitude2 * .pi / 180
        let deltaφ = (latitude2 - latitude1) * .pi / 180
        let deltaλ = (longitude2 - longitude1) * .pi / 180

        let a =
            sin(deltaφ / 2) * sin(deltaφ / 2)
            + cos(φ1) * cos(φ2) * sin(deltaλ / 2) * sin(deltaλ / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return earthRadiusMetres * c
    }

    /// Fills in `odometer` for a journey's samples, as the cumulative
    /// straight-line distance between consecutive GPS fixes.
    ///
    /// Treating each hop as a straight line rather than following the curve
    /// of the road undercounts distance slightly on bends, but GPS is
    /// sampled at 10 Hz, so consecutive points are only a metre or so apart
    /// even at motorway speeds - too close together for the difference to
    /// matter.
    static func addingOdometer(to samples: [TelemetrySample]) -> [TelemetrySample] {
        guard !samples.isEmpty else { return [] }

        var result = samples
        var total = 0.0
        for index in result.indices.dropFirst() {
            total += haversineMetres(
                latitude1: result[index - 1].latitude, longitude1: result[index - 1].longitude,
                latitude2: result[index].latitude, longitude2: result[index].longitude)
            result[index].odometer = total
        }
        return result
    }
}
