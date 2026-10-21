import DriveBuilder
import SwiftUI

/// The sheet for editing one of the journey's segments: which files beneath
/// its video directory play for that stretch of the drive, the seconds to
/// skip at the start of each source so the separately started recordings
/// play in sync, and how long it runs.
struct SegmentForm: View {
    @Environment(\.dismiss) private var dismiss

    let databasePath: String
    let segment: JourneySegment
    /// Only the last segment may leave its length to its sources.
    let isLast: Bool
    /// Runs after a successful save, so the journey pane re-reads it.
    let onSave: () -> Void

    @State private var frontFile: String
    @State private var rearFile: String
    @State private var leftFile: String
    @State private var rightFile: String
    @State private var frontOffset: String
    @State private var rearOffset: String
    @State private var telemetryOffset: String
    @State private var leftOffset: String
    @State private var rightOffset: String
    @State private var lengthText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        databasePath: String, segment: JourneySegment, isLast: Bool,
        onSave: @escaping () -> Void
    ) {
        self.databasePath = databasePath
        self.segment = segment
        self.isLast = isLast
        self.onSave = onSave
        let offsets = segment.startOffsets
        _frontFile = State(initialValue: segment.frontFile)
        _rearFile = State(initialValue: segment.rearFile)
        _leftFile = State(initialValue: segment.leftFile)
        _rightFile = State(initialValue: segment.rightFile)
        _frontOffset = State(initialValue: String(offsets.front))
        _rearOffset = State(initialValue: String(offsets.rear))
        _telemetryOffset = State(initialValue: String(offsets.telemetry))
        _leftOffset = State(initialValue: offsets.left.map { String($0) } ?? "")
        _rightOffset = State(initialValue: offsets.right.map { String($0) } ?? "")
        _lengthText = State(initialValue: segment.length.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segment \(segment.position + 1)")
                .font(.appHeadline)
            Form {
                Section("Files, in the journey's video directory") {
                    TextField("Front camera", text: $frontFile, prompt: Text("front.mov"))
                    TextField("Rear camera", text: $rearFile, prompt: Text("rear.mov"))
                    TextField("Left camera", text: $leftFile, prompt: Text("left.mov"))
                    TextField("Right camera", text: $rightFile, prompt: Text("right.mov"))
                }
                Section("Start offsets, in seconds") {
                    TextField("Front camera", text: $frontOffset, prompt: Text("e.g. 34.5"))
                    TextField("Rear camera", text: $rearOffset, prompt: Text("e.g. 34.5"))
                    TextField("Telemetry", text: $telemetryOffset, prompt: Text("e.g. 62"))
                        .help(
                            "Seconds from the journey's first telemetry sample to this "
                                + "segment's synced start")
                    TextField("Left camera", text: $leftOffset, prompt: Text("Empty if not fitted"))
                    TextField(
                        "Right camera", text: $rightOffset, prompt: Text("Empty if not fitted"))
                }
                Section("Length, in seconds") {
                    TextField(
                        "Length", text: $lengthText,
                        prompt: Text(isLast ? "Empty for shortest source" : "e.g. 2216"))
                        .help(
                            isLast
                                ? "Seconds of synced footage and telemetry this segment plays; "
                                    + "leave empty to run for its shortest source"
                                : "Seconds of synced footage and telemetry this segment plays, "
                                    + "before the next takes over")
                }
            }
            .formStyle(.grouped)
            if let problem {
                Text(problem)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
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
                .disabled(edited == nil || isSaving)
            }
        }
        .padding()
        .frame(width: 460)
    }

    /// Why the form can't be saved yet, if it can't.
    private var problem: String? {
        let files = [frontFile, rearFile, leftFile, rightFile]
        if files.contains(where: { trimmed($0).isEmpty }) {
            return "Every camera needs a file name, even one this segment doesn't use."
        }
        if [frontOffset, rearOffset, telemetryOffset].contains(where: { seconds($0) == nil }) {
            return "The front, rear, and telemetry offsets must be seconds, 0 or more."
        }
        let sideOffsets = [leftOffset, rightOffset]
        if sideOffsets.contains(where: { !trimmed($0).isEmpty && seconds($0) == nil }) {
            return "A side camera's offset must be seconds, 0 or more, or empty if not fitted."
        }
        if trimmed(lengthText).isEmpty {
            return isLast ? nil : "Only the last segment may leave its length empty."
        }
        guard let length = seconds(lengthText), length > 0 else {
            return "The length must be a positive number of seconds."
        }
        return nil
    }

    /// The segment as edited, if the form is valid.
    private var edited: JourneySegment? {
        guard problem == nil,
            let front = seconds(frontOffset), let rear = seconds(rearOffset),
            let telemetry = seconds(telemetryOffset)
        else { return nil }
        var segment = segment
        segment.frontFile = trimmed(frontFile)
        segment.rearFile = trimmed(rearFile)
        segment.leftFile = trimmed(leftFile)
        segment.rightFile = trimmed(rightFile)
        segment.startOffsets = StartOffsets(
            front: front, rear: rear, telemetry: telemetry, left: seconds(leftOffset),
            right: seconds(rightOffset))
        segment.length = seconds(lengthText)
        return segment
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// `text` as a non-negative number of seconds; decimals are fine.
    private func seconds(_ text: String) -> Double? {
        Double(trimmed(text)).flatMap { $0 >= 0 ? $0 : nil }
    }

    private func save() {
        guard let edited else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await JourneyLibrary(databasePath: databasePath).updateSegment(edited)
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
