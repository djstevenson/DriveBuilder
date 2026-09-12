import Foundation
import Testing

@testable import DriveBuilder

private func journeyDirectory(mainJSON: String?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "mainconfig-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let mainJSON {
        try Data(mainJSON.utf8).write(to: directory.appending(path: "main.json"))
    }
    return directory
}

@Test func componentOffsetsAndAnnotationsBothDecode() throws {
    let directory = try journeyDirectory(
        mainJSON: """
            {
                // JSON5: comments and trailing commas are fine.
                "components": {
                    "front": { "offset": 34.0 },
                    "rear": { "offset": 34.5 },
                    "telemetry": { "offset": 62.0 },
                },
                "annotations": [
                    { "video": "Start", "text": "We start our journey." },
                    { "video": "A27 On", "text": "We multiplex onto the A27." },
                ],
            }
            """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let config = try MainConfig.load(journeyDirectory: directory.path(percentEncoded: false))
    #expect(config.startOffsets.front == 34.0)
    #expect(config.startOffsets.rear == 34.5)
    #expect(config.startOffsets.telemetry == 62.0)
    #expect(config.annotations.map(\.video) == ["Start", "A27 On"])
    #expect(config.annotations.map(\.text) == ["We start our journey.", "We multiplex onto the A27."])
}

@Test func missingComponentsOrOffsetsDefaultToZero() throws {
    let directory = try journeyDirectory(
        mainJSON: """
            { "components": { "front": {} } }
            """)
    defer { try? FileManager.default.removeItem(at: directory) }

    let offsets = try MainConfig.load(
        journeyDirectory: directory.path(percentEncoded: false)).startOffsets
    #expect(offsets.front == 0)
    #expect(offsets.rear == 0)
    #expect(offsets.telemetry == 0)
}

@Test func missingMainJSONMeansNoOffsets() throws {
    let directory = try journeyDirectory(mainJSON: nil)
    defer { try? FileManager.default.removeItem(at: directory) }

    let offsets = try MainConfig.load(
        journeyDirectory: directory.path(percentEncoded: false)).startOffsets
    #expect(offsets.front == 0)
    #expect(offsets.rear == 0)
    #expect(offsets.telemetry == 0)
}

@Test func malformedMainJSONThrows() throws {
    let directory = try journeyDirectory(mainJSON: "{ not json at all")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: (any Error).self) {
        try MainConfig.load(journeyDirectory: directory.path(percentEncoded: false))
    }
}
