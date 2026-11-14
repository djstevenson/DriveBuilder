import Foundation
import Testing

@testable import DriveBuilder

/// The fixture journey directory's database, copied per test so the
/// checked-in file is never written to.
private let fixtureDatabase = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound/telemetry.sqlite3")

private func temporaryStore() throws -> (TelemetryStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "youtube-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appending(path: "telemetry.sqlite3")
    try FileManager.default.copyItem(at: fixtureDatabase, to: database)
    return (TelemetryStore(path: database.path), directory)
}

@Test func draftsUploadsAndUpdatesAYouTubeVideo() throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The fixture predates the feature: no table yet reads as nothing.
    #expect(try store.youtubeVideos(journeyID: 1).isEmpty)

    // The first save creates the tables and a draft row.
    let draft = try store.saveYouTubeVideo(
        journeyID: 1, variant: .fastFinal, title: "A338 fast", description: "Sped up",
        privacy: .unlisted)
    #expect(draft.journeyID == 1)
    #expect(draft.variant == .fastFinal)
    #expect(draft.title == "A338 fast")
    #expect(draft.description == "Sped up")
    #expect(draft.privacy == .unlisted)
    #expect(!draft.isUploaded)
    #expect(draft.watchURL == nil)
    #expect(draft.uploadedAt == nil)

    // Saving the same variant again updates the one row; another variant
    // gets its own, and the list comes back final first.
    let resaved = try store.saveYouTubeVideo(
        journeyID: 1, variant: .fastFinal, title: "A338 Northbound (fast)", description: "Sped up",
        privacy: .private)
    #expect(resaved.id == draft.id)
    let final = try store.saveYouTubeVideo(
        journeyID: 1, variant: .final, title: "A338 Northbound", description: "", privacy: .private)
    #expect(try store.youtubeVideos(journeyID: 1).map(\.variant) == [.final, .fastFinal])
    #expect(try store.youtubeVideos(journeyID: 1).map(\.title) == ["A338 Northbound", "A338 Northbound (fast)"])
    #expect(try store.youtubeVideos(journeyID: 999).isEmpty)

    // An upload in progress remembers its session, then completing it
    // clears the session and records the video.
    let modified = try Date("2026-11-14T10:00:00Z", strategy: .iso8601)
    try store.setYouTubeUploadSession(id: final.id, uri: "https://upload/session/1", fileModified: modified)
    var video = try #require(try store.youtubeVideos(journeyID: 1).first)
    #expect(video.uploadSessionURI == "https://upload/session/1")
    #expect(video.uploadedFileModified == modified)
    #expect(!video.isUploaded)

    let uploadedAt = try Date("2026-11-14T11:30:00Z", strategy: .iso8601)
    try store.markYouTubeVideoUploaded(
        id: final.id, videoID: "dQw4w9WgXcQ", uploadedAt: uploadedAt, fileModified: modified)
    video = try #require(try store.youtubeVideos(journeyID: 1).first)
    #expect(video.isUploaded)
    #expect(video.videoID == "dQw4w9WgXcQ")
    #expect(video.watchURL == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
    #expect(video.uploadedAt == uploadedAt)
    #expect(video.uploadedFileModified == modified)
    #expect(video.uploadSessionURI == nil)
    #expect(video.syncedAt == uploadedAt)

    // Saving metadata after upload leaves the upload columns alone.
    _ = try store.saveYouTubeVideo(
        journeyID: 1, variant: .final, title: "Renamed", description: "New text", privacy: .public)
    video = try #require(try store.youtubeVideos(journeyID: 1).first)
    #expect(video.title == "Renamed")
    #expect(video.privacy == .public)
    #expect(video.videoID == "dQw4w9WgXcQ")
    #expect(video.uploadedAt == uploadedAt)

    // A sync from YouTube rewrites the cache and its stamp.
    let syncedAt = try Date("2026-11-15T09:00:00Z", strategy: .iso8601)
    try store.updateYouTubeVideo(
        id: final.id, title: "Edited in Studio", description: "There", privacy: .unlisted,
        syncedAt: syncedAt)
    video = try #require(try store.youtubeVideos(journeyID: 1).first)
    #expect(video.title == "Edited in Studio")
    #expect(video.description == "There")
    #expect(video.privacy == .unlisted)
    #expect(video.syncedAt == syncedAt)

    try store.deleteYouTubeVideo(id: final.id)
    #expect(try store.youtubeVideos(journeyID: 1).map(\.variant) == [.fastFinal])
}

@Test func cachesPlaylistsAndMemberships() throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try store.youtubePlaylists().isEmpty)

    try store.replaceYouTubePlaylists([
        YouTubePlaylist(id: "PL1", title: "A roads"),
        YouTubePlaylist(id: "PL2", title: "Motorways"),
    ])
    #expect(try store.youtubePlaylists().map(\.title) == ["A roads", "Motorways"])

    try store.insertYouTubePlaylist(YouTubePlaylist(id: "PL3", title: "Wales"))
    #expect(try store.youtubePlaylists().map(\.id) == ["PL1", "PL2", "PL3"])

    let video = try store.saveYouTubeVideo(
        journeyID: 1, variant: .final, title: "A338", description: "", privacy: .private)
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).isEmpty)

    try store.insertYouTubePlaylistItem(
        YouTubePlaylistItem(id: "item-wales", videoRowID: video.id, playlistID: "PL3"))
    try store.insertYouTubePlaylistItem(
        YouTubePlaylistItem(id: "item-a", videoRowID: video.id, playlistID: "PL1"))
    // Back in playlist order, not insertion order.
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).map(\.playlistID) == ["PL1", "PL3"])

    try store.deleteYouTubePlaylistItem(id: "item-a")
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).map(\.id) == ["item-wales"])

    try store.replaceYouTubePlaylistItems(
        videoRowID: video.id,
        with: [
            YouTubePlaylistItem(id: "item-m", videoRowID: video.id, playlistID: "PL2"),
            YouTubePlaylistItem(id: "item-wales-2", videoRowID: video.id, playlistID: "PL3"),
        ])
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).map(\.id) == ["item-m", "item-wales-2"])

    // Refreshing the playlists drops memberships of ones that have gone.
    try store.replaceYouTubePlaylists([YouTubePlaylist(id: "PL2", title: "Motorways")])
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).map(\.id) == ["item-m"])

    // Deleting the journey takes its videos and memberships with it.
    try store.deleteJourney(id: 1)
    #expect(try store.youtubeVideos(journeyID: 1).isEmpty)
    #expect(try store.youtubePlaylistItems(videoRowID: video.id).isEmpty)
    // The playlist cache belongs to the channel, not the journey.
    #expect(try store.youtubePlaylists().count == 1)
}

@Test func variantsNameTheirOutputFiles() {
    #expect(YouTubeVideo.Variant.final.fileName == "final.mov")
    #expect(YouTubeVideo.Variant.fastFinal.fileName == "final_fast.mov")
    #expect(YouTubeVideo.Variant(rawValue: "final_fast") == .fastFinal)
}
