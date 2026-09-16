import DriveBuilder
import SwiftUI

/// The sheet for authoring a journey: just the database row's descriptive
/// fields, with the synchronisation offsets left to the offset editor.
/// Creates a new journey, or edits `journey` when one is passed.
struct JourneyForm: View {
    @Environment(\.dismiss) private var dismiss

    let databasePath: String
    /// The journey being edited; nil means the form creates a new one.
    let journey: JourneySummary?
    /// Pre-fills the source field when creating a new journey, e.g. from
    /// a folder dropped on the sidebar. Ignored when editing.
    let initialSource: String
    /// Runs after a successful save with the saved journey's id, so the
    /// sidebar can reload and select it.
    let onSave: (Int64) -> Void

    @State private var source: String
    @State private var roadType: String
    @State private var roadNumberText: String
    @State private var title: String
    @State private var isSaving = false
    @State private var saveError: String?

    private static let roadTypes = ["M", "A", "B"]

    init(
        databasePath: String, journey: JourneySummary? = nil, initialSource: String = "",
        onSave: @escaping (Int64) -> Void
    ) {
        self.databasePath = databasePath
        self.journey = journey
        self.initialSource = initialSource
        self.onSave = onSave
        _source = State(initialValue: journey?.directory ?? initialSource)
        _roadType = State(initialValue: journey?.roadType ?? "A")
        _roadNumberText = State(initialValue: journey.map { String($0.roadNumber) } ?? "")
        _title = State(initialValue: journey?.title ?? "")
    }

    /// The road number parsed as a whole number, e.g. 338 for the A338.
    private var roadNumber: Int? {
        Int(roadNumberText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(journey == nil ? "New journey" : "Edit journey")
                .font(.appHeadline)
            Form {
                TextField("Source", text: $source, prompt: Text("e.g. A338 Northbound"))
                    .help("The directory the journey's dashcam videos live in")
                Picker("Road type", selection: $roadType) {
                    ForEach(Self.roadTypes, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
                .help("Motorway, A road, or B road")
                TextField("Road number", text: $roadNumberText, prompt: Text("e.g. 338"))
                    .help("The number after the road type, e.g. 338 for the A338")
                TextField("Title", text: $title, prompt: Text("e.g. Salisbury to Ringwood"))
                    .help("The journey's display title")
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
                Button(journey == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 440)
    }

    /// The source directory and title can't be empty, and the road number
    /// must parse as a positive whole number.
    private var isValid: Bool {
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let roadNumber, roadNumber > 0 else { return false }
        return true
    }

    private func save() {
        guard let roadNumber else { return }
        isSaving = true
        saveError = nil
        let source = source.trimmingCharacters(in: .whitespaces)
        let title = title.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                let journeyID: Int64
                if let journey {
                    try await library.updateJourney(
                        id: journey.id, source: source, roadType: roadType,
                        roadNumber: roadNumber, title: title)
                    journeyID = journey.id
                } else {
                    journeyID = try await library.addJourney(
                        source: source, roadType: roadType, roadNumber: roadNumber, title: title)
                }
                onSave(journeyID)
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
