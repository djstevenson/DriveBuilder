import Foundation
import Testing

@testable import DriveBuilder

private let list = YouTubeChapterList(
    entries: [
        .init(title: "Intro + Route Map", seconds: 0),
        .init(title: "Ringwood", seconds: 754.9),
        .init(title: "Salisbury", seconds: 3725.2),
        .init(title: "Outro", seconds: 3790),
    ], movieDuration: 3810)

@Test func formatsTimestampsTheWayYouTubeReadsThem() {
    #expect(YouTubeChapterList.timestamp(0) == "0:00")
    #expect(YouTubeChapterList.timestamp(59.9) == "0:59")
    #expect(YouTubeChapterList.timestamp(754.9) == "12:34")
    #expect(YouTubeChapterList.timestamp(3725.2) == "1:02:05")
    #expect(list.text == "0:00 Intro + Route Map\n12:34 Ringwood\n1:02:05 Salisbury\n1:03:10 Outro")
}

@Test func reportsWhyYouTubeWouldShowNoChapters() {
    #expect(list.problems.isEmpty)

    let tooFew = YouTubeChapterList(
        entries: [.init(title: "Intro + Route Map", seconds: 0), .init(title: "Outro", seconds: 60)],
        movieDuration: 70)
    #expect(tooFew.problems == ["YouTube needs at least 3 chapters; the movie has 2."])

    let short = YouTubeChapterList(
        entries: [
            .init(title: "Intro + Route Map", seconds: 0), .init(title: "A", seconds: 30),
            .init(title: "B", seconds: 34), .init(title: "Outro", seconds: 100),
        ], movieDuration: 105)
    #expect(short.problems == [
        "\u{201C}A\u{201D} lasts 4 s; YouTube needs 10 s or more.",
        "\u{201C}Outro\u{201D} lasts 5 s; YouTube needs 10 s or more.",
    ])

    let late = YouTubeChapterList(
        entries: [
            .init(title: "A", seconds: 1), .init(title: "B", seconds: 30), .init(title: "C", seconds: 60),
        ], movieDuration: 100)
    #expect(late.problems == ["The first chapter must start at 0:00."])
}

@Test func insertsOrReplacesTheChapterBlockInADescription() {
    #expect(YouTubeChapterList.inserting(list.text, into: "") == list.text)
    #expect(YouTubeChapterList.inserting(list.text, into: "  \n") == list.text)
    #expect(
        YouTubeChapterList.inserting(list.text, into: "A drive up the A338.")
            == "A drive up the A338.\n\n\(list.text)")

    let existing = "A drive up the A338.\n\n0:00 Intro\n5:00 Old chapter\n\nFilmed in July."
    #expect(
        YouTubeChapterList.inserting(list.text, into: existing)
            == "A drive up the A338.\n\n\(list.text)\n\nFilmed in July.")
}
