import AVFoundation
import CoreMedia
import Foundation

/// Adds a QuickTime chapter list to a finished movie, in place: a disabled
/// text track holding one sample per chapter, associated with the video
/// track as its chapter list, which is what QuickTime Player's chapter menu
/// and `AVAsset.loadChapterMetadataGroups` read. The samples are appended
/// to the file and a new movie header written after them, so a long export
/// isn't rewritten.
enum ChapterTrackWriter {
    /// One chapter: where it starts in the movie. It runs until the next
    /// chapter starts, or the movie ends.
    struct Chapter: Sendable, Equatable {
        let title: String
        let start: CMTime
    }

    struct ChapterTrackError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Writes `chapters` (in start order, strictly increasing, the first at
    /// or after zero and all before the movie's end) into the movie at
    /// `url`, replacing any chapter track it already has.
    static func write(_ chapters: [Chapter], to url: URL) async throws {
        guard !chapters.isEmpty else { return }
        // Inspect through a plain asset, which can be loaded
        // asynchronously (AVMutableMovie isn't Sendable), then edit the
        // mutable one, whose own track accessors are synchronous.
        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration)
        guard let sourceVideoTrack = try await source.loadTracks(withMediaType: .video).first
        else {
            throw ChapterTrackError(message: "No video track in \(url.lastPathComponent).")
        }
        let oldChapterTrackIDs = try await sourceVideoTrack.loadAssociatedTracks(
            ofType: .chapterList
        ).map(\.trackID)

        for index in chapters.indices.dropFirst()
        where chapters[index].start <= chapters[index - 1].start {
            throw ChapterTrackError(
                message: "Chapters \u{201C}\(chapters[index - 1].title)\u{201D} and "
                    + "\u{201C}\(chapters[index].title)\u{201D} are out of order.")
        }
        if let first = chapters.first, first.start < .zero {
            throw ChapterTrackError(
                message: "Chapter \u{201C}\(first.title)\u{201D} starts before the movie.")
        }
        if let last = chapters.last, last.start >= duration {
            throw ChapterTrackError(
                message: "Chapter \u{201C}\(last.title)\u{201D} starts after the movie ends.")
        }

        let movie = AVMutableMovie(url: url, options: nil)
        guard let videoTrack = movie.track(withTrackID: sourceVideoTrack.trackID) else {
            throw ChapterTrackError(message: "No video track in \(url.lastPathComponent).")
        }
        // A movie re-rendered over an old file never reaches here with a
        // chapter track (the export starts afresh), but be safe.
        for old in oldChapterTrackIDs.compactMap(movie.track(withTrackID:)) {
            videoTrack.removeTrackAssociation(to: old, type: .chapterList)
            movie.removeTrack(old)
        }

        // New samples go on the end of the movie file itself.
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: url, options: nil)
        guard
            let textTrack = movie.addMutableTrack(
                withMediaType: .text, copySettingsFrom: nil, options: nil)
        else {
            throw ChapterTrackError(message: "Could not add a chapter track.")
        }
        let format = try textFormatDescription()
        for (index, chapter) in chapters.enumerated() {
            let end = index + 1 < chapters.count ? chapters[index + 1].start : duration
            let sample = try sampleBuffer(
                title: chapter.title, start: chapter.start, duration: end - chapter.start,
                format: format)
            try textTrack.append(sample, decodeTime: nil, presentationTime: nil)
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        textTrack.insertMediaTimeRange(range, into: range)
        // A chapter track is a list for the player's menu, not a subtitle to
        // draw; and `loadChapterMetadataGroups` ignores one with no language.
        textTrack.isEnabled = false
        textTrack.languageCode = "eng"
        videoTrack.addTrackAssociation(to: textTrack, type: .chapterList)
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    /// A QuickTime text sample: a 16-bit big-endian length, the UTF-8 text,
    /// and an 'encd' atom saying it's UTF-8 (text samples default to Mac
    /// Roman otherwise).
    static func sampleData(for title: String) -> Data {
        let text = Array(title.utf8.prefix(Int(UInt16.max)))
        var data = Data()
        data.append(UInt8(text.count >> 8))
        data.append(UInt8(text.count & 0xFF))
        data.append(contentsOf: text)
        for value in [UInt32(12), 0x656E_6364 /* 'encd' */, 0x0000_0100 /* UTF-8 */] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func sampleBuffer(
        title: String, start: CMTime, duration: CMTime, format: CMFormatDescription
    ) throws -> CMSampleBuffer {
        let data = sampleData(for: title)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw ChapterTrackError(message: "Could not create a chapter sample (\(status)).")
        }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                dataLength: data.count)
        }
        guard status == noErr else {
            throw ChapterTrackError(message: "Could not fill a chapter sample (\(status)).")
        }
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw ChapterTrackError(message: "Could not create a chapter sample (\(status)).")
        }
        return sample
    }

    /// The QuickTime ('text') sample description for the chapter track.
    /// Every field a 'text' description has must be given, with the exact
    /// integer widths the format uses, or appending a sample fails; the
    /// values themselves only matter to a player that draws the track,
    /// which none does for a disabled chapter list.
    private static func textFormatDescription() throws -> CMFormatDescription {
        func colour(_ level: Int16) -> [CFString: Any] {
            [
                kCMTextFormatDescriptionColor_Red: level,
                kCMTextFormatDescriptionColor_Green: level,
                kCMTextFormatDescriptionColor_Blue: level,
            ]
        }
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: Int32(0),
            kCMTextFormatDescriptionExtension_TextJustification: Int32(1),
            kCMTextFormatDescriptionExtension_BackgroundColor: colour(0),
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: Int16(0),
                kCMTextFormatDescriptionRect_Left: Int16(0),
                kCMTextFormatDescriptionRect_Bottom: Int16(0),
                kCMTextFormatDescriptionRect_Right: Int16(0),
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: Int32(0),
                kCMTextFormatDescriptionStyle_Height: Int16(0),
                kCMTextFormatDescriptionStyle_Ascent: Int16(0),
                kCMTextFormatDescriptionStyle_Font: Int16(1),
                kCMTextFormatDescriptionStyle_FontFace: Int8(0),
                kCMTextFormatDescriptionStyle_ForegroundColor: colour(Int16.max),
                kCMTextFormatDescriptionStyle_FontSize: Int16(12),
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultFontName: "Helvetica",
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_QTText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw ChapterTrackError(
                message: "Could not describe the chapter track's format (\(status)).")
        }
        return description
    }
}

extension AVAsset {
    /// The movie's chapters as `(title, start)` pairs, in order: a test and
    /// front-end convenience over `loadChapterMetadataGroups`.
    package func chapterList() async throws -> [(title: String, start: CMTime)] {
        var chapters: [(title: String, start: CMTime)] = []
        for group in try await loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"]) {
            let item = group.items.first { $0.commonKey == .commonKeyTitle } ?? group.items.first
            let title = try await item?.load(.stringValue) ?? ""
            chapters.append((title, group.timeRange.start))
        }
        return chapters
    }
}
