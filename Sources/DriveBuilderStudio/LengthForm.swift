import DriveBuilder
import SwiftUI

/// The sheet for editing the journey's drive-segment length: how many
/// seconds of synced footage and telemetry the final video plays. Left
/// empty, the drive segment runs for the shortest of the synced sources.
struct LengthForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// Runs after a successful save, so the journey list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var lengthText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(journey: JourneySummary, databasePath: String, onSave: @escaping () -> Void) {
        self.journey = journey
        self.databasePath = databasePath
        self.onSave = onSave
        _lengthText = State(initialValue: journey.length.map { String($0) } ?? "")
    }

    private var trimmedText: String {
        lengthText.trimmingCharacters(in: .whitespaces)
    }

    /// The length parsed as seconds; decimals are fine ("2400.5").
    private var length: Double? {
        Double(trimmedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drive segment length")
                .font(.appHeadline)
            Form {
                TextField(
                    "Length (seconds)", text: $lengthText,
                    prompt: Text("Empty for shortest source")
                )
                .help(
                    "Seconds of synced footage and telemetry in the final video, "
                        + "from the start offsets on; leave empty to use the shortest source")
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
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 360)
    }

    /// Empty clears the length; otherwise it must parse as a positive
    /// number of seconds.
    private var isValid: Bool {
        if trimmedText.isEmpty { return true }
        guard let length, length > 0 else { return false }
        return true
    }

    private func save() {
        let newLength = trimmedText.isEmpty ? nil : length
        isSaving = true
        saveError = nil
        Task {
            do {
                try await JourneyLibrary(databasePath: databasePath)
                    .updateLength(journeyID: journey.id, length: newLength)
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
