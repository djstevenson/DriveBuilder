import Foundation
import GRDB

struct GridPoint {
    let easting: Double
    let northing: Double
}

struct RoadEndpoint {
    let nodeID: String
    let formOfRoadNode: String?
    let location: GridPoint
}

enum RoadNetworkError: Error {
    case resourceNotFound(String)
}

final class RoadNetwork {
    enum Error: Swift.Error {
        case resourceNotFound(String)
        case roadNotFound(String)
        case insufficientEndpoints(
            roadNumber: String,
            count: Int
        )
    }
    
    private let dbQueue: DatabaseQueue

    init() throws {
        guard let url = Bundle.module.url(
            forResource: "oproad_gb",
            withExtension: "gpkg"
        ) else {
            throw RoadNetworkError.resourceNotFound("oproad_gb.gpkg")
        }

        var configuration = Configuration()
        configuration.readonly = true

        dbQueue = try DatabaseQueue(
            path: url.path,
            configuration: configuration
        )
    }

    func candidateEndpoints(for roadNumber: String) throws -> [RoadEndpoint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH road_links AS MATERIALIZED (
                        SELECT start_node, end_node
                        FROM road_link
                        WHERE road_classification_number = ?
                    ),
                    node_occurrences AS (
                        SELECT start_node AS node_id
                        FROM road_links

                        UNION ALL

                        SELECT end_node AS node_id
                        FROM road_links
                    ),
                    terminal_nodes AS (
                        SELECT node_id
                        FROM node_occurrences
                        GROUP BY node_id
                        HAVING COUNT(*) = 1
                    )
                    SELECT
                        t.node_id,
                        rn.form_of_road_node,
                        r.minx AS easting,
                        r.miny AS northing
                    FROM terminal_nodes t
                    JOIN road_node rn ON rn.id = t.node_id
                    JOIN rtree_road_node_geometry r ON r.id = rn.fid
                    ORDER BY northing, easting
                    """,
                arguments: [roadNumber]
            )

            return rows.map { row in
                let nodeID: String = row["node_id"]
                let formOfRoadNode: String? = row["form_of_road_node"]
                let easting: Double = row["easting"]
                let northing: Double = row["northing"]

                return RoadEndpoint(
                    nodeID: nodeID,
                    formOfRoadNode: formOfRoadNode,
                    location: GridPoint(
                        easting: easting,
                        northing: northing
                    )
                )
            }
        }
    }

    /// The classification number of another road sharing `nodeID`, if any -
    /// e.g. a road's dead end often turns out to be a roundabout where it
    /// meets another A-road, which is worth recording alongside the nearest
    /// settlement's name rather than instead of it.
    func junctionRoadName(at nodeID: String, excluding roadNumber: String) throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT DISTINCT road_classification_number
                    FROM road_link
                    WHERE (start_node = ? OR end_node = ?)
                      AND road_classification_number IS NOT NULL
                      AND road_classification_number != ''
                      AND road_classification_number != ?
                    LIMIT 1
                    """,
                arguments: [nodeID, nodeID, roadNumber])
            return row?["road_classification_number"]
        }
    }
}
