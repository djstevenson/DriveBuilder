import DriveBuilder
import Foundation

/// One renderable clip of a journey: its display name, where its output
/// lands, and (via `kind`) which facade call builds it.
struct RenderComponent: Identifiable, Equatable {
    enum Kind: Equatable {
        case intro
        case dials
        case routeMap
        case annotation(video: String)
        case outro
        case final
    }

    let kind: Kind
    let name: String
    /// Path of the output movie, relative to the journey directory.
    let relativePath: String

    var id: String { relativePath }

    func outputURL(journeyDirectory: String) -> URL {
        URL(filePath: journeyDirectory).appending(path: relativePath)
    }

    /// The rows for one journey, in programme order. Annotation rows come
    /// from the journey's main.json; a missing or malformed file just
    /// means no annotation rows.
    static func components(for journey: JourneySummary) -> [RenderComponent] {
        var components: [RenderComponent] = [
            RenderComponent(kind: .intro, name: "Intro", relativePath: "output/intro.mov"),
            RenderComponent(
                kind: .routeMap, name: "Route map",
                relativePath: "output/telemetry/route_map.mov"),
            RenderComponent(
                kind: .dials, name: "Dials", relativePath: "output/telemetry/dials.mov"),
        ]
        let annotations =
            (try? MainConfig.load(journeyDirectory: journey.directory).annotations) ?? []
        for annotation in annotations {
            components.append(
                RenderComponent(
                    kind: .annotation(video: annotation.video),
                    name: "Annotation \u{201C}\(annotation.video)\u{201D}",
                    relativePath: "output/\(annotation.video).mov"))
        }
        components.append(
            RenderComponent(kind: .outro, name: "Outro", relativePath: "output/outro.mov"))
        components.append(
            RenderComponent(kind: .final, name: "Final video", relativePath: "output/final.mov"))
        return components
    }
}

/// What's on disk for one component's output right now.
struct FileStatus {
    let exists: Bool
    let sizeBytes: Int64
    let modified: Date?

    init(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        exists = attributes != nil
        sizeBytes = (attributes?[.size] as? Int64) ?? 0
        modified = attributes?[.modificationDate] as? Date
    }

    var summary: String {
        guard exists else { return "Not rendered" }
        var parts = [sizeBytes.formatted(.byteCount(style: .file))]
        if let modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
