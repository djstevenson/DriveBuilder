import DriveBuilder
import SwiftUI

extension CameraOverride {
    /// Namespaced row identity for the journey pane's List, whose other
    /// sections' rows also use SQLite row ids (see `RouteMapLabel`).
    fileprivate var listRowID: String { "camera-override-\(id)" }
}

/// Keys the overrides reload to the selected journey and the toolbar's
/// Reload button.
private struct CameraOverridesLoadKey: Equatable {
    let journeyID: Int64
    let outputsVersion: Int
}

/// The journey pane's "Camera Views" section: the windows during which the
/// camera slot shows a side camera (or relabels the rear view), with add,
/// edit, and delete.
struct CameraOverridesSection: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary

    @State private var overrides: [CameraOverride] = []
    @State private var adding = false
    @State private var editing: CameraOverride?
    @State private var toDelete: CameraOverride?
    @State private var deleteError: String?

    var body: some View {
        Section {
            if overrides.isEmpty {
                Text("Rear view throughout")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(overrides, id: \.listRowID) { cameraOverride in
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
            }
        } header: {
            HStack {
                Text("Camera Views")
                Spacer()
                Button("Add", systemImage: "plus") {
                    adding = true
                }
            }
        }
        .task(id: CameraOverridesLoadKey(journeyID: journey.id, outputsVersion: model.outputsVersion)) {
            await load()
        }
        .sheet(isPresented: $adding) {
            CameraOverrideForm(
                journey: journey, databasePath: model.databasePath, otherOverrides: overrides
            ) {
                Task { await load() }
            }
        }
        .sheet(item: $editing) { cameraOverride in
            CameraOverrideForm(
                journey: journey, databasePath: model.databasePath,
                cameraOverride: cameraOverride, otherOverrides: overrides
            ) {
                Task { await load() }
            }
        }
        .alert(
            "Delete camera view?",
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
                "The \(cameraOverride.camera.displayName.lowercased()) view at "
                    + "\(ClockTime.text(for: cameraOverride.start)) will be removed; the slot "
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

    /// The row's caption: camera and window, in raw front.mov time.
    private func detail(_ cameraOverride: CameraOverride) -> String {
        "\(cameraOverride.camera.displayName) camera \u{00B7} "
            + "\(ClockTime.text(for: cameraOverride.start))\u{2013}"
            + ClockTime.text(for: cameraOverride.end)
    }

    private func load() async {
        overrides =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .cameraOverrides(journeyID: journey.id)) ?? []
    }

    private func delete(_ cameraOverride: CameraOverride) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteCameraOverride(id: cameraOverride.id)
            await load()
        } catch {
            deleteError = String(describing: error)
        }
    }
}
