import DriveBuilder
import SwiftUI

/// The journey window's Secondary Camera Selection section: the windows
/// during which the camera slot shows a side camera (or relabels the rear
/// view), with add, edit, and delete.
struct CameraOverridesSection: View {
    @Environment(\.journeyPresenter) private var presenter
    let overrides: [CameraOverride]
    /// The journey's track, for when each window opens and closes; nil
    /// while loading.
    let placement: JourneyPlacement?

    var body: some View {
        SectionPage(title: "Secondary Camera Selection") {
            Button("Add Camera Selection", systemImage: "plus") {
                presenter.showSheet(.addCameraOverride)
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
                        presenter.showSheet(.editCameraOverride(cameraOverride))
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        presenter.confirmDeletion(.cameraOverride(cameraOverride))
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
}
