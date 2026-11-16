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

@Test func appendsTheChapterBlockToADescription() {
    #expect(YouTubeChapterList.appending(list.text, to: "") == list.text)
    #expect(YouTubeChapterList.appending(list.text, to: "  \n") == list.text)
    #expect(
        YouTubeChapterList.appending(list.text, to: "A drive up the A338.\n")
            == "A drive up the A338.\n\n\(list.text)")
    // No chapters: the description goes as written.
    #expect(YouTubeChapterList.appending("", to: "A drive up the A338.\n") == "A drive up the A338.\n")
}

@Test func splitsADescriptionFromItsTrailingChapterBlock() {
    let sent = YouTubeChapterList.appending(list.text, to: "A drive up the A338.")
    let split = YouTubeChapterList.splitting(sent)
    #expect(split.body == "A drive up the A338.")
    #expect(split.chapters == list.text)

    // Only chapters, with a trailing newline.
    let alone = YouTubeChapterList.splitting(list.text + "\n")
    #expect(alone.body == "")
    #expect(alone.chapters == list.text)

    // Hour-long timestamps count too.
    #expect(YouTubeChapterList.splitting("Long one.\n\n0:00 Start\n1:02:05 End").body == "Long one.")

    // No trailing block: nothing is touched, timestamps mid-text included.
    let plain = "Left at 7:30 sharp.\n0:00 Intro\n\nFilmed in July.\n"
    #expect(YouTubeChapterList.splitting(plain).body == plain)
    #expect(YouTubeChapterList.splitting(plain).chapters == "")
}
