import Foundation

/// A point on the ground, in WGS84 degrees: where an annotation finishes, a
/// camera override starts or ends, or a route-map sign pops in. Placing
/// those by location rather than by time keeps them where they belong when
/// a journey's sync offsets change; `TrackLocator` finds when the journey
/// passed it.
package struct TrackLocation: Sendable, Hashable {
    package var latitude: Double
    package var longitude: Double

    package init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Parses a coordinate pair as signed decimal degrees, latitude first,
    /// separated by a comma: "51.0712,-1.7983", with or without spaces (as
    /// Apple Maps copies a dropped pin, and as `text` shows them). That's
    /// the one form that's quick to type, so it's the only one accepted:
    /// no degree signs or hemisphere letters. Nil if it doesn't parse or is
    /// out of range.
    package init?(parsing text: String) {
        let pattern = /^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$/
        guard let match = text.wholeMatch(of: pattern),
            let latitude = Double(match.1), let longitude = Double(match.2),
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    /// "51.07123,-1.79831": five decimal places is about a metre, finer
    /// than GPS manages, and `init(parsing:)` reads it back.
    package var text: String {
        String(format: "%.5f,%.5f", latitude, longitude)
    }
}
