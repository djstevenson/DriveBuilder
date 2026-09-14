import DriveBuilder
import SwiftUI

/// The sheet for authoring a new annotation banner: the output movie's
/// name, the text that scrolls across it, and the offset in seconds into
/// the raw front footage where the banner should finish.
struct AnnotationForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// Runs after a successful save, so the annotations list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var video = ""
    @State private var text = ""
    @State private var offsetText = ""
    @State private var isSaving = false
    @State private var saveError: String?

    /// The offset parsed as seconds; decimals are fine ("94.5").
    private var offset: Double? {
        Double(offsetText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Annotation")
                .font(.headline)
            Form {
                TextField("Video name", text: $video, prompt: Text("e.g. A27 On"))
                    .help("Names the output movie: output/<name>.mov")
                TextField("Text", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .help("What scrolls across the banner; line breaks become spaces")
                TextField("Offset (seconds)", text: $offsetText, prompt: Text("e.g. 94.5"))
                    .help(
                        "Seconds from the start of the raw front footage at which "
                            + "the banner should finish")
            }
            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 440)
    }

    /// The video name becomes a file name, so it can't be empty or contain
    /// a path separator; the text must have something to scroll; the offset
    /// must parse as a non-negative number of seconds.
    private var isValid: Bool {
        let name = video.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let offset, offset >= 0 else { return false }
        return true
    }

    private func save() {
        guard let offset else { return }
        isSaving = true
        saveError = nil
        let name = video.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await JourneyLibrary(databasePath: databasePath).addAnnotation(
                    journeyID: journey.id, video: name, text: text, offset: offset)
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
