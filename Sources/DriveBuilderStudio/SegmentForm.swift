import DriveBuilder
import SwiftUI

/// The part of a segment one of its rows edits.
enum SegmentField: Hashable {
    case front, rear, left, right, telemetry, length

    var title: String {
        switch self {
        case .front: "Front camera"
        case .rear: "Rear camera"
        case .left: "Left camera"
        case .right: "Right camera"
        case .telemetry: "Telemetry"
        case .length: "Length"
        }
    }

    /// Side cameras may be missing from a segment; front and rear may not.
    var isOptionalCamera: Bool {
        self == .left || self == .right
    }

    /// An example file name, for a camera's empty file field.
    var examplePrompt: String {
        switch self {
        case .front: "front.mov"
        case .rear: "rear.mov"
        case .left: "left.mov"
        case .right: "right.mov"
        case .telemetry, .length: ""
        }
    }
}

/// Which of a segment's rows is being edited, for the sheet's item.
struct SegmentEdit: Identifiable {
    let segment: JourneySegment
    let field: SegmentField

    var id: String { "\(segment.id)-\(field)" }
}

/// The sheet for editing one part of one of the journey's segments: a
/// camera's file beneath the video directory and the seconds to skip at its
/// start so the separately started recordings play in sync (a side camera
/// may be marked as unavailable), the telemetry's offset, or how long the
/// segment runs.
struct SegmentForm: View {
    @Environment(\.dismiss) private var dismiss

    let databasePath: String
    let segment: JourneySegment
    let field: SegmentField
    /// Only the last segment may leave its length to its sources.
    let isLast: Bool
    /// Runs after a successful save, so the journey pane re-reads it.
    let onSave: () -> Void

    @State private var isAvailable: Bool
    @State private var file: String
    @State private var offset: String
    @State private var lengthText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        databasePath: String, segment: JourneySegment, field: SegmentField, isLast: Bool,
        onSave: @escaping () -> Void
    ) {
        self.databasePath = databasePath
        self.segment = segment
        self.field = field
        self.isLast = isLast
        self.onSave = onSave
        let offsets = segment.startOffsets
        let (file, offset): (String, Double?) =
            switch field {
            case .front: (segment.frontFile, offsets.front)
            case .rear: (segment.rearFile, offsets.rear)
            case .left: (segment.leftFile, offsets.left)
            case .right: (segment.rightFile, offsets.right)
            case .telemetry: ("", offsets.telemetry)
            case .length: ("", nil)
            }
        _isAvailable = State(initialValue: !field.isOptionalCamera || offset != nil)
        _file = State(initialValue: file)
        _offset = State(initialValue: offset.map { String($0) } ?? "0.0")
        _lengthText = State(initialValue: segment.length.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segment \(segment.position + 1) \u{00B7} \(field.title)")
                .font(.appHeadline)
            Form {
                switch field {
                case .front, .rear, .left, .right:
                    cameraFields
                case .telemetry:
                    TextField("Start offset, in seconds", text: $offset, prompt: Text("e.g. 62"))
                        .help(
                            "Seconds from the journey's first telemetry sample to this "
                                + "segment's synced start")
                case .length:
                    TextField(
                        "Length, in seconds", text: $lengthText,
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

    @ViewBuilder
    private var cameraFields: some View {
        if field.isOptionalCamera {
            Toggle("Clip available", isOn: $isAvailable)
                .toggleStyle(.checkbox)
        }
        Group {
            TextField(
                "File, in the journey's video directory", text: $file,
                prompt: Text(field.examplePrompt))
            TextField("Start offset, in seconds", text: $offset, prompt: Text("e.g. 34.5"))
        }
        .disabled(!isAvailable)
    }

    /// Why the form can't be saved yet, if it can't.
    private var problem: String? {
        switch field {
        case .front, .rear, .left, .right:
            guard isAvailable else { return nil }
            if trimmed(file).isEmpty {
                return "The camera needs a file name."
            }
            if seconds(offset) == nil {
                return "The offset must be seconds, 0 or more."
            }
            return nil
        case .telemetry:
            return seconds(offset) == nil ? "The offset must be seconds, 0 or more." : nil
        case .length:
            if trimmed(lengthText).isEmpty {
                return isLast ? nil : "Only the last segment may leave its length empty."
            }
            guard let length = seconds(lengthText), length > 0 else {
                return "The length must be a positive number of seconds."
            }
            return nil
        }
    }

    /// The segment as edited, if the form is valid.
    private var edited: JourneySegment? {
        guard problem == nil else { return nil }
        var segment = segment
        // An unavailable side camera keeps its stored file name (the column
        // can't be empty); its nil offset is what marks it as missing.
        let file = isAvailable ? trimmed(file) : nil
        let offset = isAvailable ? seconds(offset) : nil
        switch field {
        case .front:
            segment.frontFile = file ?? segment.frontFile
            segment.startOffsets.front = offset ?? segment.startOffsets.front
        case .rear:
            segment.rearFile = file ?? segment.rearFile
            segment.startOffsets.rear = offset ?? segment.startOffsets.rear
        case .left:
            segment.leftFile = file ?? segment.leftFile
            segment.startOffsets.left = offset
        case .right:
            segment.rightFile = file ?? segment.rightFile
            segment.startOffsets.right = offset
        case .telemetry:
            segment.startOffsets.telemetry = offset ?? segment.startOffsets.telemetry
        case .length:
            segment.length = seconds(lengthText)
        }
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
