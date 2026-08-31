import Foundation
import GRDB

/// Looks up the nearest named settlement to a National Grid point, using
/// the OS Open Names dataset (`opname_gb.gpkg` - an SQLite/GeoPackage file
/// despite the extension, like `oproad_gb.gpkg`).
final class PlaceNameLookup {
    enum Error: Swift.Error {
        case resourceNotFound(String)
    }

    /// Settlement `local_type`s within OS Open Names' `populatedPlace`
    /// `type`: cities, towns, villages, hamlets, and suburbs - as opposed to
    /// the dataset's other named features (roads, hills, rivers, etc).
    private static let populatedPlaceType = "populatedPlace"

    /// The first box searched, in metres each way from the point. Doubled
    /// until a match is found or `maxSearchRadius` is exceeded.
    private static let initialSearchRadius = 5_000.0

    /// Covers the full length of Great Britain, so a search only comes up
    /// empty if the dataset has no settlements at all.
    private static let maxSearchRadius = 640_000.0

    private let dbQueue: DatabaseQueue

    init() throws {
        guard
            let url = Bundle.module.url(forResource: "opname_gb", withExtension: "gpkg")
        else {
            throw Error.resourceNotFound("opname_gb.gpkg")
        }

        var configuration = Configuration()
        configuration.readonly = true

        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
    }

    /// The name of the nearest city, town, village, hamlet, or suburb to
    /// `point`, or nil if the dataset has no settlement anywhere near it.
    func placeName(near point: GridPoint) throws -> String? {
        try dbQueue.read { db in
            var radius = Self.initialSearchRadius
            while radius <= Self.maxSearchRadius {
                if let name = try Self.nearestPlaceName(in: db, near: point, radius: radius) {
                    return name
                }
                radius *= 2
            }
            return nil
        }
    }

    /// The nearest settlement's name within `radius` metres of `point` in
    /// either direction, or nil if none is that close. Searches a square
    /// box via the rtree index, then ranks the (usually few) candidates
    /// inside it by true distance - the rtree itself can only test bounding
    /// box overlap, not order by distance.
    private static func nearestPlaceName(
        in db: Database, near point: GridPoint, radius: Double
    ) throws -> String? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT np.name1
                FROM rtree_named_place_geometry r
                JOIN named_place np ON np.fid = r.id
                WHERE r.minx BETWEEN ? AND ?
                  AND r.miny BETWEEN ? AND ?
                  AND np.type = ?
                ORDER BY (r.minx - ?) * (r.minx - ?) + (r.miny - ?) * (r.miny - ?)
                LIMIT 1
                """,
            arguments: [
                point.easting - radius, point.easting + radius,
                point.northing - radius, point.northing + radius,
                populatedPlaceType,
                point.easting, point.easting, point.northing, point.northing,
            ])
        return row?["name1"]
    }
}
