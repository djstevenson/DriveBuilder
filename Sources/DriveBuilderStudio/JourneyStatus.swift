import DriveBuilder
import Foundation

/// A rendered output file's size and modification date, for the journeys
/// list's tooltips.
nonisolated struct OutputFile: Sendable {
    let sizeBytes: Int64
    let modified: Date?

    var summary: String {
        var parts = [sizeBytes.formatted(.byteCount(style: .file))]
        if let modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A snapshot of how far along one journey is, for the journeys list's
/// status icons: which source files are on disk, which outputs have been
/// rendered, and how many items have been authored.
///
/// Built from the database and file `stat`s only; it never loads the
/// track, so it stays cheap enough to refresh for every journey whenever
/// the list window comes back to the front.
nonisolated struct JourneyStatus: Sendable {
    enum Camera: CaseIterable, Sendable {
        case front, rear, left, right

        var name: String {
            switch self {
            case .front: "Front camera"
            case .rear: "Rear camera"
            case .left: "Left camera"
            case .right: "Right camera"
            }
        }
    }

    enum SourcePresence: Sendable {
        /// Every segment that uses the camera has its file on disk.
        case present
        /// At least one segment that uses the camera is missing its file.
        case missing
        /// No segment uses the camera (only the side cameras can be unused).
        case unused
    }

    let segmentCount: Int
    let cameras: [Camera: SourcePresence]
    /// The rendered standard outputs, keyed by `RenderComponent.relativePath`;
    /// absent means not rendered.
    let outputs: [String: OutputFile]
    /// Every output's state (standard clips, finals, and annotation
    /// banners), keyed by its path relative to the journey directory.
    let renderStates: [String: RenderState]
    let annotationCount: Int
    /// The annotation banners' states, one per annotation.
    let annotationStates: [RenderState]
    let routeMapLabelCount: Int
    let cameraOverrideCount: Int
    /// Which of the final videos are on YouTube.
    let uploadedVariants: Set<YouTubeVideo.Variant>

    /// Reads every journey's status, off the main actor. A journey whose
    /// database rows can't be read is left out, so the list just shows no
    /// icons for it.
    @concurrent
    static func load(
        journeys: [JourneySummary], databasePath: String, outputPaths: [String]
    ) async -> [Int64: JourneyStatus] {
        let library = JourneyLibrary(databasePath: databasePath)
        var statuses: [Int64: JourneyStatus] = [:]
        for journey in journeys {
            guard
                let status = try? await load(
                    journey: journey, library: library, outputPaths: outputPaths)
            else { continue }
            statuses[journey.id] = status
        }
        return statuses
    }

    @concurrent
    private static func load(
        journey: JourneySummary, library: JourneyLibrary, outputPaths: [String]
    ) async throws -> JourneyStatus {
        let segments = try await library.segments(journeyID: journey.id)
        let annotations = try await library.annotations(journeyID: journey.id)
        let labels = try await library.routeMapLabels(journeyID: journey.id)
        let overrides = try await library.cameraOverrides(journeyID: journey.id)
        let youtubeVideos = try await library.youtubeVideos(journeyID: journey.id)

        let directory = URL(filePath: journey.directory)
        let video = directory.appending(path: "video")
        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        var cameras: [Camera: SourcePresence] = [:]
        for camera in Camera.allCases {
            // The files of the segments that use this camera: front and rear
            // always, a side camera only when the segment has its offset.
            let files = segments.compactMap { segment -> String? in
                switch camera {
                case .front: segment.frontFile
                case .rear: segment.rearFile
                case .left: segment.startOffsets.left == nil ? nil : segment.leftFile
                case .right: segment.startOffsets.right == nil ? nil : segment.rightFile
                }
            }
            cameras[camera] =
                files.isEmpty
                ? .unused
                : files.allSatisfy { exists(video.appending(path: $0)) } ? .present : .missing
        }

        var outputs: [String: OutputFile] = [:]
        for path in outputPaths {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appending(path: path).path(percentEncoded: false))
            guard let attributes else { continue }
            outputs[path] = OutputFile(
                sizeBytes: (attributes[.size] as? Int64) ?? 0,
                modified: attributes[.modificationDate] as? Date)
        }

        let renderStates = try await library.renderStates(journey: journey)
        // The same output path as `RenderComponent.component(for:)`.
        let annotationStates = annotations.map {
            renderStates["output/\($0.video).mov"] ?? .missing
        }

        return JourneyStatus(
            segmentCount: segments.count, cameras: cameras, outputs: outputs,
            renderStates: renderStates, annotationCount: annotations.count,
            annotationStates: annotationStates, routeMapLabelCount: labels.count,
            cameraOverrideCount: overrides.count,
            uploadedVariants: Set(youtubeVideos.filter(\.isUploaded).map(\.variant)))
    }
}
