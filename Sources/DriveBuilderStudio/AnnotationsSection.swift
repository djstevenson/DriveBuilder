import DriveBuilder
import SwiftUI

/// The journey window's Annotations section: the banners in the order they
/// finish, each with Render, Play, Reveal, Edit, and Delete.
struct AnnotationsSection: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.renderSettings) private var renderSettings
    @Environment(\.journeyPresenter) private var presenter
    let journey: JourneySummary
    let annotations: [Annotation]
    /// The journey's track, for when each banner finishes; nil while
    /// loading.
    let placement: JourneyPlacement?

    var body: some View {
        SectionPage(title: "Annotations") {
            if isRenderingAll {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button("Render All Annotations") {
                model.render(
                    .allAnnotations, journey: journey, settings: renderSettings,
                    origin: .journeyWindow)
            }
            .disabled(model.isRendering || annotations.isEmpty)
            Button("Add Annotation", systemImage: "plus") {
                presenter.showSheet(.addAnnotation)
            }
        } content: {
            List(sortedAnnotations) { annotation in
                HStack {
                    ComponentRow(
                        component: .component(for: annotation), journey: journey,
                        detail: detail(annotation))
                    Button("Edit", systemImage: "pencil") {
                        presenter.showSheet(.editAnnotation(annotation))
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        presenter.confirmDeletion(.annotation(annotation))
                    }
                }
            }
            .overlay {
                if annotations.isEmpty {
                    ContentUnavailableView(
                        "No annotations yet", systemImage: "text.bubble",
                        description: Text("Banners that appear over the drive."))
                }
            }
        }
    }

    private var isRenderingAll: Bool {
        guard let active = model.activeRender else { return false }
        return active.journeyID == journey.id
            && active.componentID == RenderComponent.allAnnotations.id
    }

    /// The annotations in the order they finish, once the track's loaded.
    private var sortedAnnotations: [Annotation] {
        placement?.sorted(annotations, by: \.endLocation) ?? annotations
    }

    /// The row's extra caption: when the banner finishes (or where, until
    /// the track loads), or why it can't be placed or won't fit.
    private func detail(_ annotation: Annotation) -> String {
        guard let placement else { return "Finishes at \(annotation.endLocation.text)" }
        switch placement.place(annotation.endLocation) {
        case .success(let placed):
            let finishes = "Finishes at \(placement.timeText(placed))"
            guard
                let problem = placement.annotationTimingProblem(
                    name: nil, text: annotation.text, finishingAt: placed)
            else { return finishes }
            return "\(finishes) \u{00B7} \u{26A0}\u{FE0E} \(problem)"
        case .failure(let error):
            return "Not placeable: \(error)"
        }
    }
}
