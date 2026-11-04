import DriveBuilder
import SwiftUI

/// The journey window's Annotations section: the banners in the order they
/// finish, each with Render, Play, Reveal, Edit, and Delete.
struct AnnotationsSection: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.renderSettings) private var renderSettings
    let journey: JourneySummary
    let annotations: [Annotation]
    /// The journey's track, for when each banner finishes; nil while
    /// loading.
    let placement: JourneyPlacement?
    /// Re-reads the annotations after an add, edit, or delete.
    let reload: () async -> Void

    @State private var adding = false
    @State private var editing: Annotation?
    @State private var toDelete: Annotation?
    @State private var deleteError: String?

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
                adding = true
            }
        } content: {
            List(sortedAnnotations) { annotation in
                HStack {
                    ComponentRow(
                        component: .component(for: annotation), journey: journey,
                        detail: detail(annotation))
                    Button("Edit", systemImage: "pencil") {
                        editing = annotation
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        toDelete = annotation
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
        .sheet(isPresented: $adding) {
            AnnotationForm(
                journey: journey, databasePath: model.databasePath, placement: placement
            ) {
                Task { await reload() }
            }
        }
        .sheet(item: $editing) { annotation in
            AnnotationForm(
                journey: journey, databasePath: model.databasePath, annotation: annotation,
                placement: placement
            ) {
                Task { await reload() }
            }
        }
        .alert(
            "Delete annotation?",
            isPresented: Binding(
                get: { toDelete != nil },
                set: { if !$0 { toDelete = nil } }),
            presenting: toDelete
        ) { annotation in
            Button("Delete", role: .destructive) {
                Task { await delete(annotation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { annotation in
            Text(
                "\u{201C}\(annotation.video)\u{201D} will be removed from the database. "
                    + "Its rendered movie, if any, stays on disk.")
        }
        .alert(
            "Could not delete",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
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

    private func delete(_ annotation: Annotation) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteAnnotation(id: annotation.id)
            await reload()
        } catch {
            deleteError = String(describing: error)
        }
    }
}
