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

    /// Parses a pasted or typed coordinate pair, latitude first:
    /// "51.0712, -1.7983" (as Apple Maps copies a dropped pin), or with
    /// degree signs and hemispheres, "51.0712° N, 1.7983° W" (as `text`
    /// shows them). Nil if it doesn't parse, mixes a minus sign with a
    /// hemisphere letter, or is out of range.
    package init?(parsing text: String) {
        let pattern =
            /^\s*([+-]?\d+(?:\.\d+)?)\s*°?\s*([NSns])?\s*[,\s]\s*([+-]?\d+(?:\.\d+)?)\s*°?\s*([EWew])?\s*$/
        guard let match = text.wholeMatch(of: pattern),
            let latitude = Self.degrees(String(match.1), hemisphere: match.2, negative: "s"),
            let longitude = Self.degrees(String(match.3), hemisphere: match.4, negative: "w"),
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    /// `number` in signed degrees, negated for the `negative` hemisphere.
    /// Nil if it already carries a sign as well as a hemisphere letter,
    /// which would be ambiguous ("-1.79 W").
    private static func degrees(
        _ number: String, hemisphere: Substring?, negative: Character
    ) -> Double? {
        guard let value = Double(number) else { return nil }
        guard let hemisphere else { return value }
        guard number.first != "-", number.first != "+" else { return nil }
        return hemisphere.lowercased().first == negative ? -value : value
    }

    /// "51.07120°N, 1.79830°W": five decimal places is about a metre, finer
    /// than GPS manages, and `init(parsing:)` reads it back.
    package var text: String {
        String(format: "%.5f", abs(latitude)) + (latitude < 0 ? "\u{00B0}S" : "\u{00B0}N")
            + ", "
            + String(format: "%.5f", abs(longitude)) + (longitude < 0 ? "\u{00B0}W" : "\u{00B0}E")
    }
}
