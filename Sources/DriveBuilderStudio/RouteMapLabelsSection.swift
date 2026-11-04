import DriveBuilder
import SwiftUI

/// The journey window's Route Map Labels section: the signs the route map
/// reveals, in track order, with add, edit, and delete.
struct RouteMapLabelsSection: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary
    let labels: [RouteMapLabel]
    /// The journey's track, for when each sign appears; nil while loading.
    let placement: JourneyPlacement?
    /// Re-reads the labels after an add, edit, or delete.
    let reload: () async -> Void

    @State private var adding = false
    @State private var editing: RouteMapLabel?
    @State private var toDelete: RouteMapLabel?
    @State private var deleteError: String?

    var body: some View {
        SectionPage(title: "Route Map Labels") {
            Button("Add Label", systemImage: "plus") {
                adding = true
            }
        } content: {
            List(sortedLabels) { label in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.title)
                        Text(detail(label))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        editing = label
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        toDelete = label
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if labels.isEmpty {
                    ContentUnavailableView(
                        "No route map labels yet", systemImage: "tag",
                        description: Text("Signs the route map shows as the drive reaches them."))
                }
            }
        }
        .sheet(isPresented: $adding) {
            RouteMapLabelForm(
                journey: journey, databasePath: model.databasePath, placement: placement
            ) {
                Task { await reload() }
            }
        }
        .sheet(item: $editing) { label in
            RouteMapLabelForm(
                journey: journey, databasePath: model.databasePath, label: label,
                placement: placement
            ) {
                Task { await reload() }
            }
        }
        .alert(
            "Delete route map label?",
            isPresented: Binding(
                get: { toDelete != nil },
                set: { if !$0 { toDelete = nil } }),
            presenting: toDelete
        ) { label in
            Button("Delete", role: .destructive) {
                Task { await delete(label) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { label in
            Text("\u{201C}\(label.title)\u{201D} will be removed from the database.")
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

    /// The labels in the order the track reveals them, once it's loaded.
    private var sortedLabels: [RouteMapLabel] {
        placement?.sorted(labels, by: \.revealLocation) ?? labels
    }

    /// The row's caption: when the sign appears (or where, until the track
    /// loads), which side it sits on, its gap from the track point when
    /// overridden, and the subtitle.
    private func detail(_ label: RouteMapLabel) -> String {
        var parts = [
            placement?.caption(for: label.revealLocation) ?? label.revealLocation.text,
            label.location.rawValue,
        ]
        if let distance = label.distance {
            parts.append(
                "gap \(distance.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if !label.subtitle.isEmpty {
            parts.append(label.subtitle)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func delete(_ label: RouteMapLabel) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteRouteMapLabel(id: label.id)
            await reload()
        } catch {
            deleteError = String(describing: error)
        }
    }
}
