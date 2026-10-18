import DriveBuilder
import SwiftUI

extension StartOffsetSource {
    /// The row label the offset belongs to in the journey pane.
    var displayName: String {
        switch self {
        case .front: "Front camera"
        case .rear: "Rear camera"
        case .telemetry: "Telemetry"
        case .left: "Left camera"
        case .right: "Right camera"
        }
    }
}

/// The sheet for editing one of the journey's synchronisation offsets:
/// seconds to skip at the start of that source so the separately started
/// recordings play in sync. For an optional side camera, an empty offset
/// means the journey has no such view.
struct OffsetForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    let source: StartOffsetSource
    /// Runs after a successful save, so the journey list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var offsetText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, source: StartOffsetSource,
        onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.source = source
        self.onSave = onSave
        _offsetText = State(initialValue: journey.startOffset(source).map { String($0) } ?? "")
    }

    private var trimmedText: String {
        offsetText.trimmingCharacters(in: .whitespaces)
    }

    /// The offset parsed as seconds; decimals are fine ("34.5").
    private var offset: Double? {
        Double(trimmedText)
    }

    /// An optional side camera left empty: the journey has no such view.
    private var clearsCamera: Bool {
        source.isOptional && trimmedText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(source.displayName) offset")
                .font(.appHeadline)
            Form {
                TextField(
                    "Offset (seconds)", text: $offsetText,
                    prompt: Text(source.isOptional ? "Empty if not fitted" : "e.g. 34.5")
                )
                .help(
                    source.isOptional
                        ? "Seconds skipped at the start of this camera's video so the "
                            + "separately started recordings play in sync; leave empty if "
                            + "this journey has no such view"
                        : "Seconds skipped at the start of this source so the "
                            + "separately started recordings play in sync")
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

    /// The composer treats offsets as seconds to skip, so the value must
    /// parse as a non-negative number - or, for a side camera, be empty.
    private var isValid: Bool {
        if clearsCamera { return true }
        guard let offset, offset >= 0 else { return false }
        return true
    }

    private func save() {
        guard clearsCamera || offset != nil else { return }
        let offset = clearsCamera ? nil : offset
        isSaving = true
        saveError = nil
        Task {
            do {
                try await JourneyLibrary(databasePath: databasePath)
                    .updateStartOffset(journeyID: journey.id, source: source, offset: offset)
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
