import DriveBuilder
import SwiftUI

/// The sheet for authoring a route-map label: a road-sign placard revealed
/// as the animated track reaches its offset. Creates a new label, or edits
/// `label` when one is passed.
struct RouteMapLabelForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// The label being edited; nil means the form creates a new one.
    let label: RouteMapLabel?
    /// Runs after a successful save, so the labels list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var title: String
    @State private var subtitle: String
    @State private var offsetText: String
    @State private var location: RouteMapLabel.Location
    @State private var distanceText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, label: RouteMapLabel? = nil,
        onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.label = label
        self.onSave = onSave
        _title = State(initialValue: label?.title ?? "")
        _subtitle = State(initialValue: label?.subtitle ?? "")
        _offsetText = State(initialValue: label.map { String($0.offset) } ?? "")
        _location = State(initialValue: label?.location ?? .right)
        _distanceText = State(initialValue: label?.distance.map { String($0) } ?? "")
    }

    /// The offset parsed as seconds; decimals are fine ("383.5").
    private var offset: Double? {
        Double(offsetText.trimmingCharacters(in: .whitespaces))
    }

    /// The distance parsed as a number; blank means the renderer's default
    /// gap, stored as NULL.
    private var distance: Double?? {
        let trimmed = distanceText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Double(trimmed) else { return nil }
        return .some(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label == nil ? "New route map label" : "Edit route map label")
                .font(.appHeadline)
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. Salisbury"))
                    .help("The sign's main line")
                TextField("Subtitle", text: $subtitle, prompt: Text("e.g. Historic cathedral city"))
                    .help("The sign's smaller second line; may be empty")
                TextField("Offset (seconds)", text: $offsetText, prompt: Text("e.g. 383"))
                    .help(
                        "Seconds from the start of the telemetry at which the "
                            + "track reaches the sign")
                Picker("Side", selection: $location) {
                    Text("Left").tag(RouteMapLabel.Location.left)
                    Text("Right").tag(RouteMapLabel.Location.right)
                }
                .pickerStyle(.menu)
                .help("Which side of the track the sign sits on")
                TextField("Distance", text: $distanceText, prompt: Text("default"))
                    .help("Gap between the track point and the sign; blank for the default")
            }
            if let saveError {
                Text(saveError)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(label == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 440)
    }

    /// The title is the sign's main line, so it can't be empty; the offset
    /// must parse as a non-negative number of seconds; the distance must be
    /// blank (default) or a non-negative number.
    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let offset, offset >= 0 else { return false }
        guard let distance else { return false }
        if let value = distance, value < 0 { return false }
        return true
    }

    private func save() {
        guard let offset, let distance else { return }
        isSaving = true
        saveError = nil
        let title = title.trimmingCharacters(in: .whitespaces)
        let subtitle = subtitle.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let label {
                    try await library.updateRouteMapLabel(
                        id: label.id, offset: offset, title: title, subtitle: subtitle,
                        location: location, distance: distance)
                } else {
                    try await library.addRouteMapLabel(
                        journeyID: journey.id, offset: offset, title: title, subtitle: subtitle,
                        location: location, distance: distance)
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
