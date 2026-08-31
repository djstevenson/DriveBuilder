import Foundation

/// A road's two ends, cached in the `roads` table (see `TelemetryStore`) so
/// repeated lookups don't need to re-query the OS road network and place
/// name datasets.
struct CachedRoad: Sendable {
    let roadName: String
    let startEasting: Double
    let startNorthing: Double
    let startName: String
    let endEasting: Double
    let endNorthing: Double
    let endName: String

    /// The other road's classification number where the start/end node is
    /// also shared with another classified road (e.g. "A303"), or nil if
    /// the endpoint isn't at such a junction.
    let startJunctionRoad: String?
    let endJunctionRoad: String?
}
