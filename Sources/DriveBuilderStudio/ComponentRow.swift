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
