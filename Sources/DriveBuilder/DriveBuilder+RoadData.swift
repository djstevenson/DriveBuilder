import ArgumentParser
import Foundation

/// The canonical telemetry database is the one checked into this source
/// tree (see DriveBuilder+Telemetry.swift) - cached road data must land
/// there directly, not in the bundled copy the render subcommands read,
/// which is recreated from it on every build.
private let sourceTreeDatabasePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Resources/telemetry.sqlite3")
    .path(percentEncoded: false)

extension DriveBuilder {
    struct RoadData: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "road-data",
            abstract: "Cache each A-road's endpoints in the telemetry database.",
            discussion: """
                Looks up A1 through A9999 in turn against the OS road network data; \
                for each that exists, finds its two furthest-apart candidate \
                endpoints (see RoadNetwork), the nearest named settlement to each, \
                and - where the endpoint is also a junction with another \
                classified road - that road's number, and caches the result in \
                telemetry.sqlite3's roads table. Roads already cached, and numbers \
                with no matching road, are skipped. Not part of the render \
                pipeline.
                """)

        mutating func run() async throws {
            let roads = try RoadNetwork()
            let places = try PlaceNameLookup()
            let store = TelemetryStore(path: sourceTreeDatabasePath)

            var cachedCount = 0
            for number in 1...9999 {
                let roadName = "A\(number)"
                if try store.hasCachedRoad(named: roadName) { continue }

                do {
                    let endpoints = try roads.endpoints(for: roadName)
                    let startName =
                        try places.placeName(near: endpoints.first.location) ?? "unknown place"
                    let endName =
                        try places.placeName(near: endpoints.second.location) ?? "unknown place"
                    let startJunctionRoad = try roads.junctionRoadName(
                        at: endpoints.first.nodeID, excluding: roadName)
                    let endJunctionRoad = try roads.junctionRoadName(
                        at: endpoints.second.nodeID, excluding: roadName)

                    try store.upsertRoad(
                        CachedRoad(
                            roadName: roadName,
                            startEasting: endpoints.first.location.easting,
                            startNorthing: endpoints.first.location.northing,
                            startName: startName,
                            endEasting: endpoints.second.location.easting,
                            endNorthing: endpoints.second.location.northing,
                            endName: endName,
                            startJunctionRoad: startJunctionRoad,
                            endJunctionRoad: endJunctionRoad))

                    cachedCount += 1
                    print(
                        "\(roadName): \(startName)\(startJunctionRoad.map { " (\($0))" } ?? "")"
                            + " -> \(endName)\(endJunctionRoad.map { " (\($0))" } ?? "")")
                } catch RoadNetwork.Error.roadNotFound {
                    continue
                } catch RoadNetwork.Error.insufficientEndpoints {
                    continue
                }
            }

            print("Cached \(cachedCount) road(s).")
        }
    }
}
