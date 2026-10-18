import DriveBuilder
import SwiftUI

extension CameraOverride.Camera {
    /// The picker and list name.
    var displayName: String {
        switch self {
        case .rear: "Rear"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// The sheet for authoring a camera-slot override: a window during which
/// the slot shows another camera (or the rear view with its own label).
/// Creates a new override, or edits `cameraOverride` when one is passed.
struct CameraOverrideForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// The override being edited; nil means the form creates a new one.
    let cameraOverride: CameraOverride?
    /// The journey's other overrides, to catch overlaps before saving.
    let otherOverrides: [CameraOverride]
    /// Runs after a successful save, so the list re-reads the database.
    let onSave: () -> Void

    @State private var camera: CameraOverride.Camera
    @State private var startText: String
    @State private var endText: String
    @State private var labelText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, cameraOverride: CameraOverride? = nil,
        otherOverrides: [CameraOverride], onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.cameraOverride = cameraOverride
        self.otherOverrides = otherOverrides.filter { $0.id != cameraOverride?.id }
        self.onSave = onSave
        _camera = State(initialValue: cameraOverride?.camera ?? .left)
        _startText = State(initialValue: cameraOverride?.startLocation.text ?? "")
        _endText = State(initialValue: cameraOverride?.endLocation.text ?? "")
        _labelText = State(initialValue: cameraOverride?.label ?? "")
    }

    private var start: TrackLocation? { TrackLocation(parsing: startText) }
    private var end: TrackLocation? { TrackLocation(parsing: endText) }

    /// Blank means the camera's default label, stored as NULL.
    private var label: String? {
        let trimmed = labelText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Why the current values can't be saved, if they can't; nil when valid.
    /// An unparsed location just disables Add/Save without a message. Order,
    /// length, and overlaps depend on when the track passes the locations,
    /// so the final render checks those.
    private var problem: String? {
        if camera != .rear && journey.startOffset(camera == .left ? .left : .right) == nil {
            return "This journey has no \(camera.displayName.lowercased()) camera: "
                + "set its offset under Source Video and Telemetry first."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cameraOverride == nil ? "New camera view" : "Edit camera view")
                .font(.appHeadline)
            Form {
                Picker("Camera", selection: $camera) {
                    ForEach(CameraOverride.Camera.allCases, id: \.self) { camera in
                        Text(camera.displayName).tag(camera)
                    }
                }
                .pickerStyle(.menu)
                .help("Which camera fills the slot during this window")
                TextField("Start location", text: $startText, prompt: Text("e.g. 51.0712, -1.7983"))
                    .help(
                        "Where the journey is as this camera pushes in: latitude, longitude, "
                            + "as copied from a map")
                TextField("End location", text: $endText, prompt: Text("e.g. 51.0745, -1.7968"))
                    .help("Where the journey is as the slot returns to the rear view")
                TextField("Label", text: $labelText, prompt: Text(camera.defaultLabel))
                    .help("The slot's label during this window; blank for \u{201C}\(camera.defaultLabel)\u{201D}")
            }
            if let message = problem ?? saveError {
                Text(message)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(cameraOverride == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(start == nil || end == nil || problem != nil || isSaving)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private func save() {
        guard let start, let end, problem == nil else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let cameraOverride {
                    try await library.updateCameraOverride(
                        id: cameraOverride.id, camera: camera, start: start, end: end, label: label)
                } else {
                    try await library.addCameraOverride(
                        journeyID: journey.id, camera: camera, start: start, end: end, label: label)
                }
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
