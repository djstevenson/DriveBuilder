import DriveBuilder
import SwiftUI

/// The journey window's Secondary Camera Selection section: the windows
/// during which the camera slot shows a side camera (or relabels the rear
/// view), with add, edit, and delete.
struct CameraOverridesSection: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary
    let overrides: [CameraOverride]
    /// The journey's track, for when each window opens and closes; nil
    /// while loading.
    let placement: JourneyPlacement?
    /// Re-reads the overrides after an add, edit, or delete.
    let reload: () async -> Void

    @State private var adding = false
    @State private var editing: CameraOverride?
    @State private var toDelete: CameraOverride?
    @State private var deleteError: String?

    var body: some View {
        SectionPage(title: "Secondary Camera Selection") {
            Button("Add Camera Selection", systemImage: "plus") {
                adding = true
            }
        } content: {
            List(sortedOverrides) { cameraOverride in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cameraOverride.displayLabel)
                        Text(detail(cameraOverride))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        editing = cameraOverride
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        toDelete = cameraOverride
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if overrides.isEmpty {
                    ContentUnavailableView(
                        "Rear view throughout", systemImage: "camera.viewfinder",
                        description: Text("The camera slot shows the rear camera for the whole drive."))
                }
            }
        }
        .sheet(isPresented: $adding) {
            CameraOverrideForm(
                journey: journey, databasePath: model.databasePath, otherOverrides: overrides,
                placement: placement
            ) {
                Task { await reload() }
            }
        }
        .sheet(item: $editing) { cameraOverride in
            CameraOverrideForm(
                journey: journey, databasePath: model.databasePath,
                cameraOverride: cameraOverride, otherOverrides: overrides, placement: placement
            ) {
                Task { await reload() }
            }
        }
        .alert(
            "Delete secondary camera selection?",
            isPresented: Binding(
                get: { toDelete != nil },
                set: { if !$0 { toDelete = nil } }),
            presenting: toDelete
        ) { cameraOverride in
            Button("Delete", role: .destructive) {
                Task { await delete(cameraOverride) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { cameraOverride in
            Text(
                "The \(cameraOverride.camera.displayName.lowercased()) view from "
                    + "\(cameraOverride.startLocation.text) will be removed; the slot "
                    + "shows the rear view there instead.")
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

    /// The overrides in the order the track reaches them, once it's loaded.
    private var sortedOverrides: [CameraOverride] {
        placement?.sorted(overrides, by: \.startLocation) ?? overrides
    }

    /// The row's caption: camera and when its window opens and closes (or
    /// the locations bounding it, until the track loads).
    private func detail(_ cameraOverride: CameraOverride) -> String {
        let window =
            placement.map {
                "\($0.caption(for: cameraOverride.startLocation)) \u{2192} "
                    + $0.caption(for: cameraOverride.endLocation)
            }
            ?? "\(cameraOverride.startLocation.text) \u{2192} \(cameraOverride.endLocation.text)"
        return "\(cameraOverride.camera.displayName) camera \u{00B7} \(window)"
    }

    private func delete(_ cameraOverride: CameraOverride) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteCameraOverride(id: cameraOverride.id)
            await reload()
        } catch {
            deleteError = String(describing: error)
        }
    }
}
