import DriveBuilder
import SwiftUI

/// The sheet for authoring a route-map label: a road-sign placard revealed
/// as the animated track reaches its location. Creates a new label, or edits
/// `label` when one is passed.
struct RouteMapLabelForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// The label being edited; nil means the form creates a new one.
    let label: RouteMapLabel?
    /// The journey's track, to show when the sign appears; nil while
    /// loading.
    let placement: JourneyPlacement?
    /// Runs after a successful save, so the labels list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var title: String
    @State private var subtitle: String
    @State private var locationText: String
    @State private var location: RouteMapLabel.Location
    @State private var distanceText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, label: RouteMapLabel? = nil,
        placement: JourneyPlacement?, onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.label = label
        self.placement = placement
        self.onSave = onSave
        _title = State(initialValue: label?.title ?? "")
        _subtitle = State(initialValue: label?.subtitle ?? "")
        _locationText = State(initialValue: label?.revealLocation.text ?? "")
        _location = State(initialValue: label?.location ?? .e)
        _distanceText = State(initialValue: label?.distance.map { String($0) } ?? "")
    }

    /// Where the track reveals the sign, pasted ("51.0712, -1.7983") or as
    /// displayed.
    private var revealLocation: TrackLocation? {
        TrackLocation(parsing: locationText)
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
                LocationField(
                    title: "Location", text: $locationText,
                    help: "Where the track reveals the sign: latitude, longitude, as copied "
                        + "from a map",
                    placement: placement, identifier: "route-map-label")
                Picker("Side", selection: $location) {
                    ForEach(RouteMapLabel.Location.allCases, id: \.self) { location in
                        Text(Self.title(for: location)).tag(location)
                    }
                }
                .pickerStyle(.menu)
                .help("Where the sign sits relative to the track point (the map is north-up)")
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
        .frame(width: 520)
    }

    /// The title is the sign's main line, so it can't be empty; the track must
    /// pass the location exactly once; the distance must be blank (default)
    /// or a non-negative number.
    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard isPlaceable(locationText, on: placement) else { return false }
        guard let distance else { return false }
        if let value = distance, value < 0 { return false }
        return true
    }

    private func save() {
        guard let revealLocation, let distance else { return }
        isSaving = true
        saveError = nil
        let title = title.trimmingCharacters(in: .whitespaces)
        let subtitle = subtitle.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let label {
                    try await library.updateRouteMapLabel(
                        id: label.id, revealLocation: revealLocation, title: title,
                        subtitle: subtitle,
                        location: location, distance: distance)
                } else {
                    try await library.addRouteMapLabel(
                        journeyID: journey.id, revealLocation: revealLocation, title: title,
                        subtitle: subtitle,
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

    /// The picker's wording for each compass placement.
    private static func title(for location: RouteMapLabel.Location) -> String {
        switch location {
        case .n: "N (above)"
        case .ne: "NE (above right)"
        case .e: "E (right)"
        case .se: "SE (below right)"
        case .s: "S (below)"
        case .sw: "SW (below left)"
        case .w: "W (left)"
        case .nw: "NW (above left)"
        }
    }
}
