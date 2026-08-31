import Testing

@testable import DriveBuilder

/// End-to-end checks against the bundled `oproad_gb.gpkg` resource. These
/// roads are real entries in that data, so the numbers only change if the
/// resource is replaced.
@Test func candidateEndpointsFindsA338sTerminalNodes() throws {
    let roads = try RoadNetwork()
    let candidates = try roads.candidateEndpoints(for: "A338")

    #expect(candidates.count == 15)
    // Sorted by northing then easting, so the southernmost node comes first
    // and the northernmost comes last.
    #expect(abs((candidates.first?.location.northing ?? 0) - 91592.828125) < 0.01)
    #expect(abs((candidates.last?.location.northing ?? 0) - 200662.484375) < 0.01)
}

/// A108 has no links at all in the bundled data.
@Test func candidateEndpointsIsEmptyForAnUnknownRoad() throws {
    let roads = try RoadNetwork()
    #expect(try roads.candidateEndpoints(for: "A108").isEmpty)
}

@Test func endpointsPicksTheFurthestApartPairForA338() throws {
    let roads = try RoadNetwork()
    let endpoints = try roads.endpoints(for: "A338")

    #expect(abs(endpoints.first.location.easting - 406660.1875) < 0.01)
    #expect(abs(endpoints.first.location.northing - 91592.828125) < 0.01)
    #expect(abs(endpoints.second.location.easting - 445103.25) < 0.01)
    #expect(abs(endpoints.second.location.northing - 200662.484375) < 0.01)
}

@Test func endpointsThrowsRoadNotFoundForAnUnknownRoad() throws {
    let roads = try RoadNetwork()
    do {
        _ = try roads.endpoints(for: "A108")
        Issue.record("expected an unknown road to throw")
    } catch RoadNetwork.Error.roadNotFound(let roadNumber) {
        #expect(roadNumber == "A108")
    }
}

/// A338's own southern endpoint sits at a roundabout also shared with the
/// A35, per the bundled data.
@Test func junctionRoadNameFindsTheOtherRoadAtASharedNode() throws {
    let roads = try RoadNetwork()
    let endpoints = try roads.endpoints(for: "A338")
    #expect(
        try roads.junctionRoadName(at: endpoints.first.nodeID, excluding: "A338") == "A35")
    #expect(
        try roads.junctionRoadName(at: endpoints.second.nodeID, excluding: "A338") == "A420")
}

/// A3088's two ends are roundabouts shared with the A30 (Yeovil side) and
/// the A303 respectively, per the bundled data.
@Test func junctionRoadNameFindsA3088sRoadJunctions() throws {
    let roads = try RoadNetwork()
    let endpoints = try roads.endpoints(for: "A3088")
    #expect(
        try roads.junctionRoadName(at: endpoints.first.nodeID, excluding: "A3088") == "A30")
    #expect(
        try roads.junctionRoadName(at: endpoints.second.nodeID, excluding: "A3088") == "A303")
}

/// A1012 is a real road with only one terminal node in the bundled data
/// (its other end meets another road with the same classification number,
/// so it never appears in only one link) - a naturally occurring case for
/// `insufficientEndpoints` rather than a contrived one.
@Test func endpointsThrowsInsufficientEndpointsForARoadWithOnlyOneTerminalNode() throws {
    let roads = try RoadNetwork()
    do {
        _ = try roads.endpoints(for: "A1012")
        Issue.record("expected a road with one candidate endpoint to throw")
    } catch RoadNetwork.Error.insufficientEndpoints(let roadNumber, let count) {
        #expect(roadNumber == "A1012")
        #expect(count == 1)
    }
}
