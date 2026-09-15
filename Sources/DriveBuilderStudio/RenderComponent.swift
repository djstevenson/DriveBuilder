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
        /// Every annotation banner in the database, in order.
        case allAnnotations
        case outro
        case final
        /// Every component in programme order, then the final assembly.
        case project
    }

    let kind: Kind
    let name: String
    /// Path of the output movie, relative to the journey directory.
    let relativePath: String

    var id: String { relativePath }

    func outputURL(journeyDirectory: String) -> URL {
        URL(filePath: journeyDirectory).appending(path: relativePath)
    }

    /// The synthetic whole-project component behind the header's Render All:
    /// every component in programme order, then the final assembly. It has
    /// no output file of its own — its `relativePath` only serves as a
    /// unique ID, so it must never be stat'ed or played.
    static let project = RenderComponent(
        kind: .project, name: "Whole project", relativePath: "output/project")

    /// The synthetic component behind the Annotations section's Render All:
    /// every annotation banner in the database, in order. Like `project`,
    /// it has no output file of its own — its `relativePath` only serves as
    /// a unique ID, so it must never be stat'ed or played.
    static let allAnnotations = RenderComponent(
        kind: .allAnnotations, name: "All annotations", relativePath: "output/annotations")

    /// The row for one annotation banner from the database's `annotations`
    /// table.
    static func component(for annotation: Annotation) -> RenderComponent {
        RenderComponent(
            kind: .annotation(video: annotation.video),
            name: "Annotation \u{201C}\(annotation.video)\u{201D}",
            relativePath: "output/\(annotation.video).mov")
    }

    /// The clip rows for a journey, in programme order. Annotations are not
    /// included: they live in their own section of the journey pane (see
    /// `JourneyDetailView`).
    static let standardComponents: [RenderComponent] = [
        RenderComponent(kind: .intro, name: "Intro", relativePath: "output/intro.mov"),
        RenderComponent(
            kind: .routeMap, name: "Route map",
            relativePath: "output/route_map.mov"),
        RenderComponent(kind: .dials, name: "Dials", relativePath: "output/dials.mov"),
        RenderComponent(kind: .outro, name: "Outro", relativePath: "output/outro.mov"),
        RenderComponent(kind: .final, name: "Final video", relativePath: "output/final.mov"),
    ]
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
