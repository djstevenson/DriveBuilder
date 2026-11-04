import CryptoKit
import Foundation

/// How a rendered output compares with what rendering it now would use.
package enum RenderState: Sendable, Equatable {
    /// No movie on disk.
    case missing
    /// Rendered from the current inputs, or rendered before render records
    /// existed and with nothing newer that it was assembled from.
    case upToDate
    /// Rendered, but its inputs have changed since; for the final videos,
    /// also when a clip they're assembled from has since been re-rendered
    /// or is itself out of date.
    case changed
    /// A quick-preview render: only the first part of the movie.
    case preview
}

/// What one render was made from: a fingerprint of its inputs, and
/// whether it was a quick preview. Kept per output file in the output
/// directory's `renders.json`.
struct RenderRecord: Codable, Sendable {
    var fingerprint: String
    var preview: Bool
    var renderedAt: Date
}

/// Fingerprints a journey's outputs from exactly what each render reads,
/// so a later render state can tell whether anything that matters has
/// changed. Both sides — the renderer recording what it made, and the
/// Studio checking it — build fingerprints here, so they can't disagree.
///
/// Bump an output's version when its renderer changes in a way that
/// should mark existing movies out of date.
struct RenderInputs {
    private static let versions = [
        "intro": 1, "outro": 1, "dials": 1, "route_map": 1, "annotation": 1, "final": 1,
        "final_fast": 1,
    ]

    /// The file names, under `output`, of the movies a journey's final
    /// videos are assembled from, besides its annotation banners.
    static let clipFiles = ["intro.mov", "route_map.mov", "dials.mov", "outro.mov"]
    static let finalFiles = ["final.mov", "final_fast.mov"]
    static let recordsFile = "renders.json"

    let journey: JourneySummary
    let segments: [JourneySegment]
    let annotations: [Annotation]
    let routeMapLabels: [RouteMapLabel]
    let cameraOverrides: [CameraOverride]
    let outputDirectory: URL

    init(store: TelemetryStore, journey: JourneySummary) throws {
        self.journey = journey
        segments = try store.journeySegments(journeyID: journey.id)
        annotations = try store.annotations(journeyID: journey.id)
        routeMapLabels = try store.routeMapLabels(journeyID: journey.id)
        cameraOverrides = try store.cameraOverrides(journeyID: journey.id)
        outputDirectory = URL(filePath: journey.directory).appending(path: "output")
    }

    /// Every output file the journey can have: the standard clips, the
    /// final videos, and one banner per annotation.
    var allFiles: [String] {
        Self.clipFiles + Self.finalFiles + annotations.map { "\($0.video).mov" }
    }

    /// The fingerprint of what rendering `file` now would use; nil for a
    /// file that isn't one of the journey's outputs.
    func fingerprint(for file: String) -> String? {
        let parts: [String]
        switch file {
        case "intro.mov":
            parts = component("intro") + road
        case "outro.mov":
            parts = component("outro") + road
        case "dials.mov":
            parts = component("dials") + telemetry + drive
        case "route_map.mov":
            parts = component("route_map") + telemetry + drive + routeMapLabels.map { "\($0)" }
        case "final.mov":
            parts =
                component("final") + finalInputs
                + annotations.map { "\($0.video) \($0.endLocation)" }
                + clipDates(Self.clipFiles + annotations.map { "\($0.video).mov" })
        case "final_fast.mov":
            parts = component("final_fast") + finalInputs + clipDates(Self.clipFiles)
        default:
            guard let annotation = annotations.first(where: { "\($0.video).mov" == file })
            else { return nil }
            parts =
                component("annotation")
                + [DriveBuilder.Annotations.normalizedText(annotation.text)]
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func component(_ name: String) -> [String] {
        [name, "v\(Self.versions[name] ?? 0)"]
    }

    private var road: [String] {
        [journey.roadType, "\(journey.roadNumber)", journey.title]
    }

    /// The telemetry, by its extent rather than every sample: re-extracting
    /// changes at least one of these.
    private var telemetry: [String] {
        [
            "\(journey.sampleCount)",
            "\(journey.start?.timeIntervalSince1970 ?? 0)",
            "\(journey.end?.timeIntervalSince1970 ?? 0)",
        ]
    }

    /// What the drive's timeline is cut from: each segment's stretch of
    /// telemetry, in order. Camera files and offsets don't move it.
    private var drive: [String] {
        segments.map { "\($0.startOffsets.telemetry) \($0.length.map { "\($0)" } ?? "open")" }
    }

    /// What both final videos read from the database: the footage and its
    /// sync, the drive, and the camera overrides.
    private var finalInputs: [String] {
        telemetry + segments.map { "\($0)" } + cameraOverrides.map { "\($0)" }
    }

    /// The assembled clips' modification dates, so re-rendering one marks
    /// the final videos out of date.
    private func clipDates(_ files: [String]) -> [String] {
        files.map { file in
            modificationDate(of: file).map { "\(file) \($0.timeIntervalSince1970)" }
                ?? "\(file) missing"
        }
    }

    func modificationDate(of file: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: outputDirectory.appending(path: file).path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - Records

    func loadRecords() -> [String: RenderRecord] {
        guard
            let data = try? Data(
                contentsOf: outputDirectory.appending(path: Self.recordsFile))
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: RenderRecord].self, from: data)) ?? [:]
    }

    /// Records that `file` was just rendered from the current inputs.
    func record(_ file: String, preview: Bool) throws {
        guard let fingerprint = fingerprint(for: file) else { return }
        var records = loadRecords()
        records[file] = RenderRecord(fingerprint: fingerprint, preview: preview, renderedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(
            to: outputDirectory.appending(path: Self.recordsFile), options: .atomic)
    }

    // MARK: - States

    /// Every output's state, keyed by file name.
    func states() -> [String: RenderState] {
        let records = loadRecords()
        var states: [String: RenderState] = [:]
        for file in allFiles {
            states[file] = ownState(of: file, record: records[file])
        }
        // A final video is only as current as the clips it's assembled
        // from.
        let annotationFiles = annotations.map { "\($0.video).mov" }
        for (file, clips) in [
            ("final.mov", Self.clipFiles + annotationFiles), ("final_fast.mov", Self.clipFiles),
        ] where states[file] == .upToDate {
            if clips.contains(where: { states[$0] != .upToDate }) {
                states[file] = .changed
            }
        }
        return states
    }

    private func ownState(of file: String, record: RenderRecord?) -> RenderState {
        guard let modified = modificationDate(of: file) else { return .missing }
        guard let record else {
            // Rendered before records existed: nothing to compare inputs
            // against, but a final video older than a clip it's assembled
            // from is still out of date.
            let clips =
                file == "final.mov"
                ? Self.clipFiles + annotations.map { "\($0.video).mov" }
                : file == "final_fast.mov" ? Self.clipFiles : []
            let newerClip = clips.contains {
                (modificationDate(of: $0) ?? .distantPast) > modified
            }
            return newerClip ? .changed : .upToDate
        }
        if record.preview { return .preview }
        return record.fingerprint == fingerprint(for: file) ? .upToDate : .changed
    }
}

extension JourneyLibrary {
    /// The state of each of the journey's outputs, keyed by its path
    /// relative to the journey directory (`output/<name>.mov`).
    ///
    /// `@concurrent` for the same reason as `journeys()`: keep the database
    /// read off the caller's (GUI main) actor.
    @concurrent
    package func renderStates(journey: JourneySummary) async throws -> [String: RenderState] {
        let inputs = try RenderInputs(store: TelemetryStore(path: databasePath), journey: journey)
        var states: [String: RenderState] = [:]
        for (file, state) in inputs.states() {
            states["output/\(file)"] = state
        }
        return states
    }
}
