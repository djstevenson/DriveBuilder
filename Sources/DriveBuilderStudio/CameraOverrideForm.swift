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
    /// The journey's track, to show when the window opens and closes and
    /// check its length and overlaps; nil while loading.
    let placement: JourneyPlacement?
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
        otherOverrides: [CameraOverride], placement: JourneyPlacement?,
        onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.cameraOverride = cameraOverride
        self.otherOverrides = otherOverrides.filter { $0.id != cameraOverride?.id }
        self.placement = placement
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
    /// A location that doesn't parse or place just disables Add/Save, its
    /// field saying why. Order, length, and overlaps go by when the track
    /// passes the locations, so they wait for the track to load.
    private var problem: String? {
        let sideClock: JourneyPlacement.Clock? =
            switch camera {
            case .rear: nil
            case .left: .left
            case .right: .right
            }
        if let placement, let sideClock, !placement.clocks.contains(sideClock) {
            return "This journey has no \(camera.displayName.lowercased()) camera: "
                + "set its offset in a segment first."
        }
        guard let placement, let window = windowSeconds(from: start, to: end, on: placement) else {
            return nil
        }
        // A window ending exactly at a join belongs to the segment before.
        let segment = placement.segmentIndex(atDriveSeconds: window.start)
        if window.end > window.start,
            placement.segmentIndex(atDriveSeconds: window.end - 0.001) != segment
        {
            return "Runs across the join between segments \(segment + 1) and \(segment + 2): "
                + "split it into a view for each segment."
        }
        if let sideClock, !placement.segment(segment, has: sideClock) {
            return "Segment \(segment + 1) has no \(camera.displayName.lowercased()) camera: "
                + "set its offset in that segment first."
        }
        if window.end <= window.start {
            return "The track reaches the end location before the start location."
        }
        if window.end - window.start < CameraOverride.minimumDuration {
            return "Too short: a secondary camera selection needs at least "
                + "\(CameraOverride.minimumDuration.formatted()) s for the camera to push "
                + "in, its label to appear, and the camera to push back out."
        }
        for other in otherOverrides {
            guard
                let otherWindow = windowSeconds(
                    from: other.startLocation, to: other.endLocation, on: placement),
                window.start < otherWindow.end, otherWindow.start < window.end
            else { continue }
            return "Overlaps the \(other.camera.displayName.lowercased()) view from "
                + "\(placement.caption(for: other.startLocation)); only one camera can fill "
                + "the slot at a time."
        }
        return nil
    }

    /// When the track passes `start` and `end`, in drive seconds; nil if
    /// either is missing or can't be placed.
    private func windowSeconds(
        from start: TrackLocation?, to end: TrackLocation?, on placement: JourneyPlacement
    ) -> (start: Double, end: Double)? {
        guard let start, let end,
            case .success(let opens) = placement.place(start),
            case .success(let closes) = placement.place(end)
        else { return nil }
        return (opens.driveSeconds, closes.driveSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                cameraOverride == nil
                    ? "New secondary camera selection" : "Edit secondary camera selection")
                .font(.appHeadline)
            Form {
                Picker("Camera", selection: $camera) {
                    ForEach(CameraOverride.Camera.allCases, id: \.self) { camera in
                        Text(camera.displayName).tag(camera)
                    }
                }
                .pickerStyle(.menu)
                .help("Which camera fills the slot during this window")
                LocationField(
                    title: "Start location", text: $startText,
                    help: "Where the journey is as this camera pushes in: latitude, longitude, "
                        + "as copied from a map",
                    placement: placement, identifier: "camera-view-start")
                LocationField(
                    title: "End location", text: $endText,
                    help: "Where the journey is as the slot returns to the rear view",
                    placement: placement, identifier: "camera-view-end")
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
                .disabled(
                    !isPlaceable(startText, on: placement) || !isPlaceable(endText, on: placement)
                        || problem != nil || isSaving)
            }
        }
        .padding()
        .frame(width: 520)
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
