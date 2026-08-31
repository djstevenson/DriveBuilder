import Testing

@testable import DriveBuilder

/// End-to-end checks against the bundled `opname_gb.gpkg` resource. These
/// points are A338's real endpoints (see RoadNetworkTests.swift), so the
/// names only change if the resource is replaced.
@Test func placeNameFindsTheNearestSettlementToA338sSouthernEnd() throws {
    let places = try PlaceNameLookup()
    let name = try places.placeName(near: GridPoint(easting: 406660.1875, northing: 91592.828125))
    #expect(name == "Westbourne")
}

@Test func placeNameFindsTheNearestSettlementToA338sNorthernEnd() throws {
    let places = try PlaceNameLookup()
    let name = try places.placeName(
        near: GridPoint(easting: 445103.25, northing: 200662.484375))
    #expect(name == "Appleton")
}

/// Far outside the National Grid's real extent (which tops out around
/// 655,000 E / 1,216,000 N), so no settlement is within even the largest
/// search box.
@Test func placeNameIsNilFarOutsideGreatBritain() throws {
    let places = try PlaceNameLookup()
    let name = try places.placeName(near: GridPoint(easting: 2_000_000, northing: 2_000_000))
    #expect(name == nil)
}
