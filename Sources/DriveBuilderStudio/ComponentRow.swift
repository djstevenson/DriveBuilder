import AppKit
import DriveBuilder
import SwiftUI

struct ComponentRow: View {
    @Environment(StudioModel.self) private var model
    let component: RenderComponent
    let journey: JourneySummary

    @State private var showingPlayer = false

    var body: some View {
        // Reading outputsVersion re-evaluates the row (and so re-stats the
        // file) whenever a render finishes or the toolbar reload runs.
        let _ = model.outputsVersion
        let url = component.outputURL(journeyDirectory: journey.directory)
        let status = FileStatus(url: url)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                Text(status.summary)
                    .font(.caption)
                    .foregroundStyle(status.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            Spacer()
            if isRenderingThis {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button("Render") {
                model.render(component, journey: journey)
            }
            .disabled(model.isRendering)
            Button("Play", systemImage: "play.fill") {
                showingPlayer = true
            }
            .disabled(!status.exists)
            Button("Reveal", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!status.exists)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingPlayer) {
            MoviePlayerView(url: url, title: component.name)
        }
    }

    private var isRenderingThis: Bool {
        guard let active = model.activeRender else { return false }
        return active.journeyID == journey.id && active.componentID == component.id
    }
}

/// One node of the component tree: a plain `ComponentRow` for leaves, and
/// for groups a disclosure row (expanded by default) whose label carries
/// the group name and its bulk "Render All" button.
struct ComponentTreeRow: View {
    @Environment(StudioModel.self) private var model
    let node: ComponentNode
    let journey: JourneySummary

    @State private var isExpanded = true

    var body: some View {
        switch node.content {
        case .component(let component):
            ComponentRow(component: component, journey: journey)
        case .group(let name, let renderAll):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    ComponentTreeRow(node: child, journey: journey)
                }
            } label: {
                HStack {
                    Text(name)
                        .font(.headline)
                    Spacer()
                    if let renderAll {
                        if isRendering(renderAll) {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Button("Render All") {
                            model.render(renderAll, journey: journey)
                        }
                        .disabled(model.isRendering)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func isRendering(_ component: RenderComponent) -> Bool {
        guard let active = model.activeRender else { return false }
        return active.journeyID == journey.id && active.componentID == component.id
    }
}
