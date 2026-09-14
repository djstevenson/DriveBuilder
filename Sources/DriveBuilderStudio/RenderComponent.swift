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
        /// Every annotation banner in main.json, in order.
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

    /// The component tree for one journey, in programme order. The root is
    /// a "Whole project" group wrapping everything; annotation rows come
    /// from the journey's main.json and sit in a nested group with their
    /// own render-all. A missing or malformed main.json just means no
    /// annotation group.
    static func tree(for journey: JourneySummary) -> ComponentNode {
        var children: [ComponentNode] = [
            .component(
                RenderComponent(kind: .intro, name: "Intro", relativePath: "output/intro.mov")),
            .component(
                RenderComponent(
                    kind: .routeMap, name: "Route map",
                    relativePath: "output/telemetry/route_map.mov")),
            .component(
                RenderComponent(
                    kind: .dials, name: "Dials", relativePath: "output/telemetry/dials.mov")),
        ]
        let annotations =
            (try? MainConfig.load(journeyDirectory: journey.directory).annotations) ?? []
        if !annotations.isEmpty {
            children.append(
                .group(
                    name: "Annotations",
                    renderAll: RenderComponent(
                        kind: .allAnnotations, name: "All annotations",
                        relativePath: "output/annotations"),
                    children: annotations.map { annotation in
                        .component(
                            RenderComponent(
                                kind: .annotation(video: annotation.video),
                                name: "Annotation \u{201C}\(annotation.video)\u{201D}",
                                relativePath: "output/\(annotation.video).mov"))
                    }))
        }
        children.append(
            .component(
                RenderComponent(kind: .outro, name: "Outro", relativePath: "output/outro.mov")))
        children.append(
            .component(
                RenderComponent(
                    kind: .final, name: "Final video", relativePath: "output/final.mov")))
        return .group(
            name: "Whole project",
            renderAll: RenderComponent(
                kind: .project, name: "Whole project", relativePath: "output/project"),
            children: children)
    }
}

/// A node in the component tree: either one renderable row, or a named
/// group whose row carries a bulk "Render All" action over everything
/// beneath it. Groups nest to any depth.
struct ComponentNode: Identifiable {
    enum Content {
        case component(RenderComponent)
        /// `renderAll` is a synthetic component with no output file of its
        /// own — its `relativePath` only serves as a unique ID, so it must
        /// never be stat'ed or played.
        case group(name: String, renderAll: RenderComponent?)
    }

    let content: Content
    let children: [ComponentNode]?

    static func component(_ component: RenderComponent) -> ComponentNode {
        ComponentNode(content: .component(component), children: nil)
    }

    static func group(
        name: String, renderAll: RenderComponent?, children: [ComponentNode]
    ) -> ComponentNode {
        ComponentNode(content: .group(name: name, renderAll: renderAll), children: children)
    }

    var id: String {
        switch content {
        case .component(let component): component.id
        case .group(let name, _): "group:\(name)"
        }
    }

    /// Every component in the subtree including synthetic render-alls, for
    /// lookups like naming the active render in the progress bar.
    var allComponents: [RenderComponent] {
        var components: [RenderComponent] = []
        switch content {
        case .component(let component):
            components.append(component)
        case .group(_, let renderAll):
            if let renderAll { components.append(renderAll) }
        }
        for child in children ?? [] {
            components.append(contentsOf: child.allComponents)
        }
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
