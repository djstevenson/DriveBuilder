import Foundation
import Testing

@testable import DriveBuilder

/// A journey directory containing a real telemetry.sqlite3, checked into the
/// repo so these tests don't depend on anything outside it.
private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound")

/// A copy of the fixture database in its own temporary directory, with
/// journey 1's source pointed at that directory so its output lands there.
private struct Workspace {
    let directory: URL
    let store: TelemetryStore
    let journeyID: Int64 = 1

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "render-records-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "output"), withIntermediateDirectories: true)
        let database = directory.appending(path: "telemetry.sqlite3")
        try FileManager.default.copyItem(
            at: fixtureDirectory.appending(path: "telemetry.sqlite3"), to: database)
        store = TelemetryStore(path: database.path(percentEncoded: false))
        try store.updateJourney(
            id: journeyID, source: directory.path(percentEncoded: false), roadType: "A",
            roadNumber: 338, title: "Ringwood to Salisbury")
    }

    var inputs: RenderInputs {
        get throws {
            try RenderInputs(store: store, journey: #require(try store.journeySummary(journeyID: 1)))
        }
    }

    /// Writes a stand-in movie, dated `secondsAgo` in the past so tests
    /// control which clips are newer than which.
    func writeMovie(_ file: String, secondsAgo: Double = 60) throws {
        let url = directory.appending(path: "output/\(file)")
        try Data([0]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)],
            ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Writes a stand-in movie and records it as rendered from the current
    /// inputs.
    func render(_ file: String, secondsAgo: Double = 60, preview: Bool = false) throws {
        try writeMovie(file, secondsAgo: secondsAgo)
        try inputs.record(file, preview: preview)
    }

    func states() throws -> [String: RenderState] {
        try inputs.states()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func outputsWithoutMoviesAreMissing() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }

    let states = try workspace.states()
    #expect(states["intro.mov"] == .missing)
    #expect(states["final.mov"] == .missing)
}

@Test func moviesRenderedBeforeRecordsCountAsUpToDate() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try workspace.writeMovie("intro.mov")

    #expect(try workspace.states()["intro.mov"] == .upToDate)
}

@Test func recordedMovieGoesOutOfDateWhenItsInputsChange() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try workspace.render("intro.mov")
    try workspace.render("dials.mov")
    #expect(try workspace.states()["intro.mov"] == .upToDate)

    try workspace.store.updateJourney(
        id: 1, source: workspace.directory.path(percentEncoded: false), roadType: "A",
        roadNumber: 338, title: "Salisbury to Ringwood")

    let states = try workspace.states()
    #expect(states["intro.mov"] == .changed)
    // The dials don't show the title.
    #expect(states["dials.mov"] == .upToDate)
}

@Test func quickPreviewIsReportedAsSuch() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    try workspace.render("outro.mov", preview: true)

    #expect(try workspace.states()["outro.mov"] == .preview)
}

@Test func changingACameraFileOnlyAffectsTheFinalVideos() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    for clip in RenderInputs.clipFiles {
        try workspace.render(clip, secondsAgo: 120)
    }
    try workspace.render("final.mov")
    #expect(try workspace.states()["final.mov"] == .upToDate)

    var segment = try #require(workspace.store.journeySegments(journeyID: 1).first)
    segment.frontFile = "other-front.mp4"
    try workspace.store.updateSegment(segment)

    let states = try workspace.states()
    #expect(states["dials.mov"] == .upToDate)
    #expect(states["route_map.mov"] == .upToDate)
    #expect(states["final.mov"] == .changed)
}

@Test func addingAChapterOnlyAffectsTheFinalVideos() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    for clip in RenderInputs.clipFiles {
        try workspace.render(clip, secondsAgo: 120)
    }
    try workspace.render("final.mov")
    try workspace.render("final_fast.mov")
    #expect(try workspace.states()["final.mov"] == .upToDate)
    #expect(try workspace.states()["final_fast.mov"] == .upToDate)

    try workspace.store.insertChapter(
        journeyID: 1, title: "Ringwood",
        location: TrackLocation(latitude: 50.83991, longitude: -1.81230))

    let states = try workspace.states()
    #expect(states["dials.mov"] == .upToDate)
    #expect(states["route_map.mov"] == .upToDate)
    #expect(states["final.mov"] == .changed)
    #expect(states["final_fast.mov"] == .changed)
}

@Test func reRenderingAClipMarksTheFinalVideoOutOfDate() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    for clip in RenderInputs.clipFiles {
        try workspace.render(clip, secondsAgo: 120)
    }
    try workspace.render("final_fast.mov")
    #expect(try workspace.states()["final_fast.mov"] == .upToDate)

    try workspace.render("intro.mov", secondsAgo: 10)

    #expect(try workspace.states()["final_fast.mov"] == .changed)
}

@Test func finalVideoIsOutOfDateWhileAClipIs() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    for clip in RenderInputs.clipFiles {
        try workspace.render(clip, secondsAgo: 120)
    }
    try workspace.render("final.mov")

    // The intro's inputs change, but it hasn't been re-rendered yet.
    try workspace.store.updateJourney(
        id: 1, source: workspace.directory.path(percentEncoded: false), roadType: "A",
        roadNumber: 338, title: "Salisbury to Ringwood")

    let states = try workspace.states()
    #expect(states["intro.mov"] == .changed)
    #expect(states["final.mov"] == .changed)
}

@Test func editingAnAnnotationsTextMarksOnlyItsBannerOutOfDate() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    let location = TrackLocation(latitude: 50.9, longitude: -1.8)
    try workspace.store.insertAnnotation(
        journeyID: 1, video: "bridge", text: "A bridge", endLocation: location)
    try workspace.store.insertAnnotation(
        journeyID: 1, video: "river", text: "A river", endLocation: location)
    try workspace.render("bridge.mov")
    try workspace.render("river.mov")

    let bridge = try #require(workspace.store.annotations(journeyID: 1).first { $0.video == "bridge" })
    try workspace.store.updateAnnotation(
        id: bridge.id, video: "bridge", text: "An old bridge", endLocation: location)

    let states = try workspace.states()
    #expect(states["bridge.mov"] == .changed)
    #expect(states["river.mov"] == .upToDate)
}

@Test func legacyFinalVideoOlderThanAClipIsOutOfDate() throws {
    let workspace = try Workspace()
    defer { workspace.remove() }
    for clip in RenderInputs.clipFiles {
        try workspace.writeMovie(clip, secondsAgo: 120)
    }
    try workspace.writeMovie("final.mov", secondsAgo: 60)
    #expect(try workspace.states()["final.mov"] == .upToDate)

    try workspace.writeMovie("dials.mov", secondsAgo: 10)

    #expect(try workspace.states()["final.mov"] == .changed)
}
