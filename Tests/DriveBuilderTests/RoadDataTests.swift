import ArgumentParser
import Testing

@testable import DriveBuilder

@Test func roadDataTakesNoArguments() throws {
    _ = try DriveBuilder.RoadData.parse([])
}

@Test func roadDataRejectsTheOldRoadOption() {
    #expect(throws: (any Error).self) {
        try DriveBuilder.RoadData.parse(["--road", "A6"])
    }
}
