import AVFoundation
import Foundation

/// A movie's chapters as YouTube wants them in a description: one line per
/// chapter, a timestamp then the title, which YouTube turns into its own
/// chapter UI. YouTube ignores the chapter track in the file itself.
///
/// Read from the rendered movie rather than the database, so the times are
/// the ones in the file: the fast final's are sped up, and the automatic
/// intro marker is included.
package struct YouTubeChapterList: Sendable, Equatable {
    package struct Entry: Sendable, Equatable {
        package let title: String
        package let seconds: Double

        package init(title: String, seconds: Double) {
            self.title = title
            self.seconds = seconds
        }
    }

    /// YouTube needs at least this many timestamps to show chapters…
    package static let minimumCount = 3
    /// …each at least this long.
    package static let minimumLength = 10.0

    package let entries: [Entry]
    package let movieDuration: Double

    package init(entries: [Entry], movieDuration: Double) {
        self.entries = entries
        self.movieDuration = movieDuration
    }

    /// The chapter list in the movie at `url`; empty entries if it has no
    /// chapter track.
    package static func read(movieURL url: URL) async throws -> YouTubeChapterList {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let chapters = try await asset.chapterList()
        return YouTubeChapterList(
            entries: chapters.map { Entry(title: $0.title, seconds: $0.start.seconds) },
            movieDuration: duration)
    }

    /// The lines for the description, e.g. "0:00 Intro + Route Map".
    package var text: String {
        entries.map { "\(Self.timestamp($0.seconds)) \($0.title)" }.joined(separator: "\n")
    }

    /// Why YouTube would show no chapters for this list; empty when it
    /// would show them.
    package var problems: [String] {
        var problems: [String] = []
        if entries.count < Self.minimumCount {
            problems.append("YouTube needs at least \(Self.minimumCount) chapters; the movie has \(entries.count).")
        }
        if let first = entries.first, Self.timestamp(first.seconds) != "0:00" {
            problems.append("The first chapter must start at 0:00.")
        }
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].seconds : movieDuration
            let length = end - entry.seconds
            if length < Self.minimumLength {
                problems.append(
                    "\u{201C}\(entry.title)\u{201D} lasts \(Int(length.rounded())) s; YouTube needs "
                        + "\(Int(Self.minimumLength)) s or more.")
            }
        }
        return problems
    }

    /// `m:ss`, or `h:mm:ss` from an hour, rounded down to the second.
    package static func timestamp(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// `description` as YouTube should get it: with the chapter lines
    /// `chapters` after a blank line, or alone if the description was
    /// empty. The description unchanged if there are no chapters.
    package static func appending(_ chapters: String, to description: String) -> String {
        guard !chapters.isEmpty else { return description }
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? chapters : "\(body)\n\n\(chapters)"
    }

    /// Undoes `appending`: a description from YouTube split into the
    /// author's own words and the chapter block that ends it (the last run
    /// of lines starting with a timestamp); empty chapters, and the
    /// description untouched, if it doesn't end with one.
    package static func splitting(_ description: String) -> (body: String, chapters: String) {
        var lines = description.components(separatedBy: .newlines)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var chapters: [String] = []
        while let last = lines.last,
            last.range(of: #"^\d+:\d\d(:\d\d)?\s"#, options: .regularExpression) != nil
        {
            chapters.insert(last, at: 0)
            lines.removeLast()
        }
        guard !chapters.isEmpty else { return (description, "") }
        return (
            lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            chapters.joined(separator: "\n")
        )
    }
}
