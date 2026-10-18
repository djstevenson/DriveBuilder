import AVFoundation
import AppKit
import Foundation
import QuartzCore

/// Seconds to skip at the start of each separately recorded component so
/// they play in sync: the cameras and the telemetry logger don't all start
/// recording at the same moment. Read from the journey's database row
/// (`front_offset`, `rear_offset`, `telemetry_offset`, `left_offset`,
/// `right_offset`).
struct StartOffsets {
    var front = 0.0
    var rear = 0.0
    var telemetry = 0.0
    /// The optional side cameras: nil when the journey has no such view.
    var left: Double?
    var right: Double?
}

/// Stitches the already-rendered clips into the final programme:
/// intro → route map → (drive footage with the rear-view inset and dials on
/// top) → outro, with a one-second cross-fade between each. The dials clip
/// (dials.mov) is a standalone semi-transparent overlay (see
/// `TelemetryVideoRenderer`); this is where it finally gets composited over
/// the journey's own front and rear camera footage, rather than that
/// happening when dials.mov itself is rendered — so each component can be
/// built and checked on its own, and future additions (e.g. annotations)
/// just become another layer here.
struct FinalVideoComposer {
    let introURL: URL
    let routeMapURL: URL
    let dialsURL: URL
    let frontFootageURL: URL
    let rearFootageURL: URL
    let outroURL: URL

    /// The optional side cameras' footage (video/left.mov, video/right.mov):
    /// nil when the journey has no such view. A side camera only appears in
    /// the camera slot during its `cameraOverrides` windows, in sync by
    /// skipping its own `startOffsets.left`/`.right`, so it only has to
    /// cover those windows - it doesn't limit the drive segment's length.
    var leftFootageURL: URL?
    var rightFootageURL: URL?

    /// Windows during which the camera slot (where the rear view sits,
    /// top-left) shows another camera, or the rear view with its own label.
    /// Times are in raw front.mov seconds, like annotation offsets. They
    /// mustn't overlap; each change dissolves over `cameraDissolveSeconds`.
    var cameraOverrides: [CameraOverride] = []

    /// How long the camera slot takes to dissolve from one camera (and its
    /// label) to another.
    static let cameraDissolveSeconds = 0.3

    /// The camera slot's label: a tag in the slot's top-left corner, styled
    /// like the annotation banner (translucent black, yellow Helvetica).
    static let cameraLabelHeight = 52
    static let cameraLabelFontSize = 30.0
    static let cameraLabelPadding = 16.0

    /// Length of each cross-fade between clips.
    var crossFadeSeconds: Double = 1.0

    /// The gap the overlays keep from the frame's edges: the rear-view inset
    /// sits this far from the top and left, the dial column this far from
    /// the top, bottom, and right, and the annotation banners this far from
    /// the left and bottom.
    static let defaultEdgeInset = 20.0

    /// Gap between the frame's edges and the rear-view inset, dial column,
    /// and annotation banners (see `defaultEdgeInset`).
    var edgeInset = defaultEdgeInset

    /// Seconds skipped at the start of each drive-segment source (from the
    /// journey's database row) so the separately started recordings play in
    /// sync; the telemetry offset applies to the dials clip rendered from it.
    var startOffsets = StartOffsets()

    /// The drive segment's length in seconds (the journey's `length`
    /// column), measured from the synced start. Every drive-segment source
    /// must have at least this much left after its start offset, or the
    /// composition fails. `nil` runs the drive segment for whichever source
    /// is shortest, truncating the others to match.
    var driveSegmentLength: Double?

    /// Caps the drive segment (dials/footage/rear-view) to at most this many
    /// seconds, for a quick test render while checking sync — e.g. the first
    /// 30 seconds — rather than the whole journey. The intro and outro
    /// always play in full; `nil` renders the drive segment at full length.
    var maxDriveSegmentSeconds: Double?

    /// One rendered annotation banner (see `Annotations`) to composite over
    /// the drive segment.
    struct AnnotationClip {
        let url: URL
        /// Seconds from the start of the raw front.mov file — before that
        /// file's own `startOffsets.front` is applied — at which the
        /// annotation should finish. This is the annotation row's own
        /// "offset", not yet adjusted to the synced drive-segment timeline.
        let rawEndOffsetSeconds: Double
    }

    /// Annotations to composite over the drive segment, in the frame's
    /// bottom-left corner, each ending at its own `rawEndOffsetSeconds`.
    var annotationClips: [AnnotationClip] = []

    var framesPerSecond: Int32 = 30

    /// Called with the export's 0...1 fraction as it runs, for a front end's
    /// progress bar; when nil the CLI's periodic stdout report is used instead.
    var progressHandler: (@Sendable (Double) -> Void)?

    struct MissingClipError: Error, CustomStringConvertible {
        let url: URL
        var description: String {
            "Missing clip \(url.path(percentEncoded: false)); render it first."
        }
    }

    struct CompositionError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// How a clip is sized and positioned within the render frame.
    private enum Placement {
        /// Scaled to fit entirely within the frame, centred.
        case fitCentred
        /// Scaled to fit within the frame less `inset` on the top, bottom,
        /// and right (never enlarged), vertically centred, `inset` from the
        /// right edge — for the dial column. A column rendered at the
        /// default size fits exactly at native size.
        case fitTrailing(inset: Double)
        /// Scaled to fill the frame, centred, cropping any overflow.
        case fill
        /// Native size, its top-left corner at the given frame offset.
        case pinned(x: Double, y: Double)
        /// Scaled (keeping its aspect ratio) to cover `rect`, its top-left
        /// corner at the rect's - for a camera filling the camera slot.
        case filling(CGRect)
        /// Native size, `inset` from the frame's left and bottom edges — for
        /// the annotation banners, so they share the dial column's bottom
        /// edge and the rear-view inset's left edge.
        case pinnedBottomLeading(inset: Double)
    }

    /// One instruction still under construction: a time range and its
    /// active layers, kept as plain data (rather than the immutable
    /// `AVVideoCompositionInstruction`) so annotations can later split a
    /// range and splice their own layer into just the overlapping piece.
    private struct Phase {
        var range: CMTimeRange
        var layers: [AVVideoCompositionLayerInstruction]
    }

    /// An optional side camera's footage and sync offset.
    private struct SideCamera {
        let url: URL
        let clip: Clip
        /// Where in the source the synced drive segment begins.
        let sourceStart: CMTime
    }

    /// A camera override placed on the final timeline.
    private struct CameraWindow {
        let override: CameraOverride
        let range: CMTimeRange
    }

    private struct Clip {
        // An AVAssetTrack doesn't retain its asset, so the clip must keep
        // the asset alive itself or later track operations fail with -11800.
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        /// Display size: `AVAssetTrack.naturalSize` is the raw encoded size,
        /// before `preferredTransform` is applied, so a rotated track (e.g.
        /// a dashcam mounted upside down) needs its width and height swapped.
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    private func loadClip(at url: URL) async throws -> Clip {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw MissingClipError(url: url)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionError(message: "No video track in \(url.lastPathComponent).")
        }
        let (timeRange, encodedSize, transform) = try await track.load(
            .timeRange, .naturalSize, .preferredTransform)
        let displaySize = CGRect(origin: .zero, size: encodedSize)
            .applying(transform).standardized.size
        return Clip(
            asset: asset, track: track,
            duration: timeRange.duration, naturalSize: displaySize, preferredTransform: transform)
    }

    func writeMovie(to url: URL) async throws {
        let started = ContinuousClock.now

        let intro = try await loadClip(at: introURL)
        let routeMap = try await loadClip(at: routeMapURL)
        let dials = try await loadClip(at: dialsURL)
        let frontFootage = try await loadClip(at: frontFootageURL)
        let rearFootage = try await loadClip(at: rearFootageURL)
        let outro = try await loadClip(at: outroURL)

        let timescale: CMTimeScale = 600
        let fade = CMTime(seconds: crossFadeSeconds, preferredTimescale: timescale)

        // The route map is the full-screen element, so it sets the frame
        // size; the narrower intro and outro are scaled to fit and centred,
        // the dial column is scaled to fit and right-aligned, the drive
        // footage fills the frame (cropping any overflow) as the backdrop,
        // and the camera slot shows the rear view at native size near the
        // top-left.
        let renderSize = routeMap.naturalSize

        // The drive-segment sources were recorded separately, so each skips
        // its own start offset to bring them into sync; what competes for
        // "shortest" below is the remainder after that skip.
        func sourceStart(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: timescale)
        }
        let dialsSourceStart = sourceStart(startOffsets.telemetry)
        let frontSourceStart = sourceStart(startOffsets.front)

        let rearSourceStart = sourceStart(startOffsets.rear)

        // The side cameras the journey has (an offset and a file); a side
        // camera's clip is only loaded when an override actually uses it.
        var sideCameras: [CameraOverride.Camera: SideCamera] = [:]
        for (camera, url, offset) in [
            (CameraOverride.Camera.left, leftFootageURL, startOffsets.left),
            (CameraOverride.Camera.right, rightFootageURL, startOffsets.right),
        ] {
            guard let url, let offset, cameraOverrides.contains(where: { $0.camera == camera })
            else { continue }
            sideCameras[camera] = SideCamera(
                url: url, clip: try await loadClip(at: url), sourceStart: sourceStart(offset))
        }

        var offsetDescriptions = [
            String(format: "front %.1fs", startOffsets.front),
            String(format: "rear %.1fs", startOffsets.rear),
            String(format: "telemetry %.1fs", startOffsets.telemetry),
        ]
        if let left = startOffsets.left {
            offsetDescriptions.append(String(format: "left %.1fs", left))
        }
        if let right = startOffsets.right {
            offsetDescriptions.append(String(format: "right %.1fs", right))
        }
        print("final: start offsets \(offsetDescriptions.joined(separator: ", ")).")

        // Timeline: each clip starts one fade-length before its predecessor
        // ends. The dials overlay, the rear view, and the drive footage
        // beneath them run together for whichever is shortest.
        let introEnd = intro.duration
        let routeStart = introEnd - fade
        let routeEnd = routeStart + routeMap.duration
        let dialsStart = routeEnd - fade
        let driveClips =
            [
                ("dials.mov", dials.duration - dialsSourceStart),
                (frontFootageURL.lastPathComponent, frontFootage.duration - frontSourceStart),
                (rearFootageURL.lastPathComponent, rearFootage.duration - rearSourceStart),
            ]
        if let empty = driveClips.first(where: { $0.1 <= .zero }) {
            throw CompositionError(
                message: "The journey's start offset for \(empty.0) skips the whole clip.")
        }
        var dialsSegmentDuration = driveClips.map(\.1).min()!
        if let driveSegmentLength {
            let length = CMTime(seconds: driveSegmentLength, preferredTimescale: timescale)
            if let short = driveClips.first(where: { $0.1 < length }) {
                throw CompositionError(
                    message: String(
                        format: "The journey's length is %.1fs, but %@ only has %.1fs "
                            + "after its start offset.",
                        driveSegmentLength, short.0, short.1.seconds))
            }
            print(String(format: "final: drive segment length set to %.1fs.", driveSegmentLength))
            dialsSegmentDuration = length
        } else if driveClips.contains(where: { $0.1 != dialsSegmentDuration }) {
            let shortest = driveClips.min { $0.1 < $1.1 }!.0
            print(
                "final: \(shortest) is the shortest of "
                    + driveClips.map(\.0).joined(separator: "/")
                    + " after start offsets; truncating the others to match.")
        }
        if let maxDriveSegmentSeconds {
            let cap = CMTime(seconds: maxDriveSegmentSeconds, preferredTimescale: timescale)
            if cap < dialsSegmentDuration {
                print(
                    String(
                        format: "final: capping the drive segment to %.1fs for a test render.",
                        maxDriveSegmentSeconds))
                dialsSegmentDuration = cap
            }
        }
        let dialsEnd = dialsStart + dialsSegmentDuration
        let outroStart = dialsEnd - fade
        let outroEnd = outroStart + outro.duration

        let cameraWindows = try placeCameraOverrides(
            sideCameras: sideCameras, dialsStart: dialsStart,
            visibleRange: CMTimeRange(start: routeEnd, end: outroStart), timescale: timescale)

        let composition = AVMutableComposition()
        guard
            let trackA = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let trackB = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let footageTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let rearTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw CompositionError(message: "Could not create composition tracks.")
        }
        // One track per side camera in use, holding just its windows.
        var sideTracks: [CameraOverride.Camera: AVMutableCompositionTrack] = [:]
        for camera in sideCameras.keys {
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw CompositionError(message: "Could not create composition tracks.")
            }
            sideTracks[camera] = track
        }

        // Adjacent clips sit on different tracks so they can overlap during
        // the fades, alternating A, B, A, B along the timeline. The drive
        // footage and the rear view run underneath/alongside the dials
        // clip for the whole dials segment, so they each need a track of
        // their own rather than sharing A.
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: intro.duration),
            of: intro.track, at: .zero)
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: routeMap.duration),
            of: routeMap.track, at: routeStart)
        try trackA.insertTimeRange(
            CMTimeRange(start: dialsSourceStart, duration: dialsSegmentDuration),
            of: dials.track, at: dialsStart)
        try footageTrack.insertTimeRange(
            CMTimeRange(start: frontSourceStart, duration: dialsSegmentDuration),
            of: frontFootage.track, at: dialsStart)
        try rearTrack.insertTimeRange(
            CMTimeRange(start: rearSourceStart, duration: dialsSegmentDuration),
            of: rearFootage.track, at: dialsStart)
        for window in cameraWindows {
            guard let side = sideCameras[window.override.camera],
                let track = sideTracks[window.override.camera]
            else { continue }
            try track.insertTimeRange(
                CMTimeRange(
                    start: side.sourceStart + (window.range.start - dialsStart),
                    duration: window.range.duration),
                of: side.clip.track, at: window.range.start)
        }
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: outro.duration),
            of: outro.track, at: outroStart)

        // The front camera also provides the drive segment's sound: its
        // audio is inserted in the same synced, truncated window as its
        // picture, fading in and out with the video cross-fades either
        // side. The rest of the programme stays silent.
        var audioMix: AVAudioMix?
        if let frontAudio = try await frontFootage.asset.loadTracks(withMediaType: .audio).first {
            guard
                let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw CompositionError(message: "Could not create composition tracks.")
            }
            try audioTrack.insertTimeRange(
                CMTimeRange(start: frontSourceStart, duration: dialsSegmentDuration),
                of: frontAudio, at: dialsStart)

            let fadeParameters = AVMutableAudioMixInputParameters(track: audioTrack)
            fadeParameters.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: dialsStart, end: routeEnd))
            fadeParameters.setVolumeRamp(
                fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: outroStart, end: dialsEnd))
            let mix = AVMutableAudioMix()
            mix.inputParameters = [fadeParameters]
            audioMix = mix
        } else {
            print(
                "final: \(frontFootageURL.lastPathComponent) has no audio track; "
                    + "the output will be silent.")
        }

        // The camera slot: the rear view's frame, which every camera fills.
        let slotRect = CGRect(
            x: edgeInset, y: edgeInset,
            width: rearFootage.naturalSize.width, height: rearFootage.naturalSize.height)

        // Core Animation supplies a transparent synthetic track, composited
        // just above the camera slot: the slot's soft shadow (masked to
        // outside the slot, so it can't darken the picture) and its labels.
        let rearShadowTrackID: CMPersistentTrackID = 0x53484457
        let shadowCanvas = Self.cameraSlotOverlay(
            slotRect: slotRect, renderSize: renderSize, windows: cameraWindows,
            totalSeconds: outroEnd.seconds)
        let shadowAnimationTool = AVVideoCompositionCoreAnimationTool(
            additionalLayer: shadowCanvas, asTrackID: rearShadowTrackID)

        func layerInstruction(
            track: AVCompositionTrack, clip: Clip,
            placement: Placement = .fitCentred,
            opacityRamp: AVVideoCompositionLayerInstruction.OpacityRamp? = nil,
            additionalOpacityRamps: [AVVideoCompositionLayerInstruction.OpacityRamp] = []
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: track)
            let placementTransform: CGAffineTransform
            switch placement {
            case .filling(let rect):
                let scale = max(
                    rect.width / clip.naturalSize.width, rect.height / clip.naturalSize.height)
                placementTransform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                    .scaledBy(x: scale, y: scale)
            case .pinned(let x, let y):
                placementTransform = CGAffineTransform(translationX: x, y: y)
            case .pinnedBottomLeading(let inset):
                placementTransform = CGAffineTransform(
                    translationX: inset, y: renderSize.height - inset - clip.naturalSize.height)
            case .fitCentred, .fitTrailing, .fill:
                let scale: Double
                switch placement {
                case .fill:
                    scale = max(
                        renderSize.width / clip.naturalSize.width,
                        renderSize.height / clip.naturalSize.height)
                case .fitTrailing(let inset):
                    // Never enlarged, so a column that already fits keeps
                    // its native pixels; an older, taller render shrinks.
                    scale = min(
                        1,
                        (renderSize.width - 2 * inset) / clip.naturalSize.width,
                        (renderSize.height - 2 * inset) / clip.naturalSize.height)
                default:
                    scale = min(
                        renderSize.width / clip.naturalSize.width,
                        renderSize.height / clip.naturalSize.height)
                }
                let scaledWidth = clip.naturalSize.width * scale
                let x =
                    if case .fitTrailing(let inset) = placement {
                        renderSize.width - inset - scaledWidth
                    } else {
                        (renderSize.width - scaledWidth) / 2
                    }
                placementTransform = CGAffineTransform(
                    translationX: x,
                    y: (renderSize.height - clip.naturalSize.height * scale) / 2
                ).scaledBy(x: scale, y: scale)
            }
            // Un-rotate the source's own encoded orientation first, then
            // place it in the frame; for our own rendered clips this
            // transform is always identity, so it's a no-op.
            configuration.setTransform(
                clip.preferredTransform.concatenating(placementTransform), at: .zero)
            if let opacityRamp {
                configuration.addOpacityRamp(opacityRamp)
            }
            for ramp in additionalOpacityRamps {
                configuration.addOpacityRamp(ramp)
            }
            return AVVideoCompositionLayerInstruction(configuration: configuration)
        }

        func shadowLayerInstruction(
            opacityRamp: AVVideoCompositionLayerInstruction.OpacityRamp? = nil
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                trackID: rearShadowTrackID)
            if let opacityRamp {
                configuration.addOpacityRamp(opacityRamp)
            }
            return AVVideoCompositionLayerInstruction(configuration: configuration)
        }

        var phases: [Phase] = []
        func addInstruction(
            from start: CMTime, to end: CMTime,
            layers: [AVVideoCompositionLayerInstruction]
        ) {
            phases.append(Phase(range: CMTimeRange(start: start, end: end), layers: layers))
        }

        // Intro alone.
        addInstruction(
            from: .zero, to: routeStart,
            layers: [layerInstruction(track: trackA, clip: intro)])

        // Intro fades out over the route map.
        addInstruction(
            from: routeStart, to: introEnd,
            layers: [
                layerInstruction(
                    track: trackA, clip: intro,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: routeStart, end: introEnd),
                        start: 1, end: 0)),
                layerInstruction(track: trackB, clip: routeMap),
            ])

        // Route map alone.
        addInstruction(
            from: introEnd, to: dialsStart,
            layers: [layerInstruction(track: trackB, clip: routeMap)])

        let dialsPlacement = Placement.fitTrailing(inset: edgeInset)
        let rearPlacement = Placement.pinned(x: slotRect.minX, y: slotRect.minY)

        // Route map fades out over the drive footage, camera slot, and dial
        // column. The Core Animation track (the slot's shadow and labels)
        // sits just above the slot.
        addInstruction(
            from: dialsStart, to: routeEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: routeMap,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: dialsStart, end: routeEnd),
                        start: 1, end: 0)),
                layerInstruction(track: trackA, clip: dials, placement: dialsPlacement),
                shadowLayerInstruction(),
                layerInstruction(track: rearTrack, clip: rearFootage, placement: rearPlacement),
                layerInstruction(track: footageTrack, clip: frontFootage, placement: .fill),
            ])

        // Drive footage, camera slot, and dial column alone.
        addInstruction(
            from: routeEnd, to: outroStart,
            layers: [
                layerInstruction(track: trackA, clip: dials, placement: dialsPlacement),
                shadowLayerInstruction(),
                layerInstruction(track: rearTrack, clip: rearFootage, placement: rearPlacement),
                layerInstruction(track: footageTrack, clip: frontFootage, placement: .fill),
            ])

        // Drive footage, camera slot, and dial column fade out together
        // while the outro fades in.
        let outroFade = AVVideoCompositionLayerInstruction.OpacityRamp(
            timeRange: CMTimeRange(start: outroStart, end: dialsEnd), start: 1, end: 0)
        addInstruction(
            from: outroStart, to: dialsEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: outro,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 0, end: 1)),
                layerInstruction(
                    track: trackA, clip: dials, placement: dialsPlacement,
                    opacityRamp: outroFade),
                shadowLayerInstruction(opacityRamp: outroFade),
                layerInstruction(
                    track: rearTrack, clip: rearFootage, placement: rearPlacement,
                    opacityRamp: outroFade),
                layerInstruction(
                    track: footageTrack, clip: frontFootage, placement: .fill,
                    opacityRamp: outroFade),
            ])

        // Outro alone.
        addInstruction(
            from: dialsEnd, to: outroEnd,
            layers: [layerInstruction(track: trackB, clip: outro)])

        // Splits `phases` at `range`'s bounds (if it doesn't already land on
        // a boundary) and adds `layer` to every resulting phase inside it,
        // so an annotation can overlay an arbitrary window without
        // disturbing the cross-fades already covering that time. `layer`
        // goes first in each layer list — the topmost, per the convention
        // every other call to `layerInstruction` above already follows —
        // or it would render hidden behind the opaque front footage.
        func insertOverlay(
            _ layer: AVVideoCompositionLayerInstruction, over range: CMTimeRange
        ) {
            insertLayer(layer, over: range) { _ in 0 }
        }

        // As `insertOverlay`, but at the index `position` picks in each
        // affected phase's layer list (front to back).
        func insertLayer(
            _ layer: AVVideoCompositionLayerInstruction, over range: CMTimeRange,
            at position: ([AVVideoCompositionLayerInstruction]) -> Int
        ) {
            var result: [Phase] = []
            for phase in phases {
                let start = max(phase.range.start, range.start)
                let end = min(phase.range.end, range.end)
                guard start < end else {
                    result.append(phase)
                    continue
                }
                if phase.range.start < start {
                    result.append(
                        Phase(
                            range: CMTimeRange(start: phase.range.start, end: start),
                            layers: phase.layers))
                }
                var layers = phase.layers
                layers.insert(layer, at: position(layers))
                result.append(Phase(range: CMTimeRange(start: start, end: end), layers: layers))
                if end < phase.range.end {
                    result.append(
                        Phase(range: CMTimeRange(start: end, end: phase.range.end), layers: phase.layers))
                }
            }
            phases = result
        }

        // Each side-camera window covers the rear view, directly above it
        // (below the slot's labels), dissolving in and out.
        let dissolve = CMTime(seconds: Self.cameraDissolveSeconds, preferredTimescale: timescale)
        for window in cameraWindows {
            guard let side = sideCameras[window.override.camera],
                let track = sideTracks[window.override.camera]
            else { continue }
            let range = window.range
            insertLayer(
                layerInstruction(
                    track: track, clip: side.clip, placement: .filling(slotRect),
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: range.start, duration: dissolve),
                        start: 0, end: 1),
                    additionalOpacityRamps: [
                        .init(
                            timeRange: CMTimeRange(start: range.end - dissolve, end: range.end),
                            start: 1, end: 0)
                    ]),
                over: range
            ) { layers in
                layers.firstIndex { $0.trackID == rearTrack.trackID } ?? 0
            }
        }

        // Annotations composite over the drive segment, in the bottom-left
        // corner (the banner's own width stops it a grid gap short of the
        // dial column, whose bottom map also finishes on the bottom edge), each
        // ending at its own offset (from the annotations table, adjusted here from
        // "since the start of raw front.mov" to the synced drive-segment
        // timeline) and playing through its own built-in
        // opening/scrolling/closing animation, so no opacity ramp is needed.
        for annotationClip in annotationClips {
            let clip = try await loadClip(at: annotationClip.url)
            let syncedEndSeconds = annotationClip.rawEndOffsetSeconds - startOffsets.front
            let end = dialsStart + CMTime(seconds: syncedEndSeconds, preferredTimescale: timescale)
            let start = end - clip.duration
            guard start >= dialsStart, end <= dialsEnd else {
                print(
                    String(
                        format: "final: skipping %@ — its offset doesn't fall within the drive "
                            + "segment (%.1fs to %.1fs).",
                        annotationClip.url.lastPathComponent, dialsStart.seconds, dialsEnd.seconds))
                continue
            }
            guard
                let annotationTrack = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw CompositionError(message: "Could not create composition tracks.")
            }
            try annotationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: clip.duration), of: clip.track, at: start)
            insertOverlay(
                layerInstruction(track: annotationTrack, clip: clip, placement: .pinnedBottomLeading(inset: edgeInset)),
                over: CMTimeRange(start: start, end: end))
        }

        let instructions = phases.map {
            AVVideoCompositionInstruction(
                configuration: .init(layerInstructions: $0.layers, timeRange: $0.range))
        }

        // Without an explicit target space, a composition just propagates
        // "the source's" colour tag per source — and our own rendered clips
        // (dials/intro/outro/route map) never get one explicitly written,
        // so VideoToolbox guesses one from each clip's pixel dimensions.
        // Mixed against the dashcam footage's own (correctly tagged) Rec.
        // 709, that mismatch is exactly what washes the dial/map artwork
        // out to grey: conforming everything to Rec. 709 here removes the
        // ambiguity.
        let videoComposition = AVVideoComposition(
            configuration: .init(
                animationTool: shadowAnimationTool,
                colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                frameDuration: CMTime(value: 1, timescale: framesPerSecond),
                instructions: instructions,
                renderSize: renderSize))

        print(
            String(
                format: "final: %.1fs at %dx%d %d fps.",
                outroEnd.seconds, Int(renderSize.width), Int(renderSize.height),
                framesPerSecond))

        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
        else {
            throw CompositionError(message: "Could not create the export session.")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix

        // A full-length export takes many minutes, so report progress
        // periodically while it runs: to the handler when a front end
        // installed one, otherwise to stdout for the CLI.
        let handler = progressHandler
        let states = session.states(updateInterval: handler == nil ? 15 : 0.5)
        let monitor = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    if let handler {
                        handler(progress.fractionCompleted)
                    } else {
                        print(
                            String(
                                format: "final: exporting, %.0f%% complete",
                                progress.fractionCompleted * 100))
                    }
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mov)

        let elapsed = started.duration(to: .now)
        let seconds = elapsed / .seconds(1)
        print(
            String(
                format: "final: wrote %.1fs in %.1fs to %@",
                outroEnd.seconds, seconds, url.path(percentEncoded: false)))
    }

    // MARK: - Camera slot

    /// Validates `cameraOverrides` and places them on the final timeline:
    /// raw front.mov seconds become drive-segment time, clamped to
    /// `visibleRange` (after the route map, before the outro). Throws for a
    /// window that's empty, overlaps another, uses a camera the journey
    /// doesn't have, or runs past the end of that camera's video.
    private func placeCameraOverrides(
        sideCameras: [CameraOverride.Camera: SideCamera], dialsStart: CMTime,
        visibleRange: CMTimeRange, timescale: CMTimeScale
    ) throws -> [CameraWindow] {
        func time(_ seconds: Double) -> String {
            let total = max(0, seconds)
            return String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
        }
        func describe(_ override: CameraOverride) -> String {
            "The \(override.camera.rawValue) camera override at \(time(override.start))"
                + "-\(time(override.end))"
        }

        let overrides = cameraOverrides.sorted { $0.start < $1.start }
        for override in overrides where override.end <= override.start {
            throw CompositionError(message: "\(describe(override)) ends before it starts.")
        }
        for (previous, next) in zip(overrides, overrides.dropFirst()) where next.start < previous.end {
            throw CompositionError(
                message: "\(describe(next)) overlaps \(describe(previous).lowercased()); "
                    + "only one camera can fill the slot at a time.")
        }

        let minimum = CMTime(
            seconds: 2 * Self.cameraDissolveSeconds, preferredTimescale: timescale)
        var windows: [CameraWindow] = []
        for override in overrides {
            let side = sideCameras[override.camera]
            if override.camera != .rear && side == nil {
                throw CompositionError(
                    message: "\(describe(override)) needs the journey's \(override.camera.rawValue) "
                        + "camera, but it has no \(override.camera.rawValue)_offset.")
            }
            func finalTime(_ rawSeconds: Double) -> CMTime {
                dialsStart
                    + CMTime(seconds: rawSeconds - startOffsets.front, preferredTimescale: timescale)
            }
            let start = max(finalTime(override.start), visibleRange.start)
            let end = min(finalTime(override.end), visibleRange.end)
            guard end - start >= minimum else {
                print("final: skipping \(describe(override).lowercased()); it falls outside the drive segment.")
                continue
            }
            if let side {
                let sourceEnd = side.sourceStart + (end - dialsStart)
                if sourceEnd > side.clip.duration {
                    throw CompositionError(
                        message: "\(describe(override)) runs past the end of "
                            + "\(side.url.lastPathComponent).")
                }
            }
            windows.append(CameraWindow(override: override, range: CMTimeRange(start: start, end: end)))
        }
        return windows
    }

    /// The Core Animation layer composited just above the camera slot: the
    /// slot's drop shadow, masked to outside the slot, and the slot's
    /// labels - the rear view's by default, each override's during its
    /// window - dissolving with the cameras. Built from plain values, so the
    /// layers can be handed to the animation tool.
    private static func cameraSlotOverlay(
        slotRect: CGRect, renderSize: CGSize, windows: [CameraWindow], totalSeconds: Double
    ) -> CALayer {
        // The animation tool's layer geometry has a bottom-left origin. The
        // layer mutations run inside an explicit CATransaction: this runs
        // off the main thread, where an implicit transaction would be left
        // uncommitted when the thread exits (and aborts outright under
        // CA_ASSERT_MAIN_THREAD_TRANSACTIONS).
        let bounds = CGRect(origin: .zero, size: renderSize)
        let slot = CGRect(
            x: slotRect.minX, y: renderSize.height - slotRect.maxY,
            width: slotRect.width, height: slotRect.height)

        CATransaction.begin()
        defer { CATransaction.commit() }
        let canvas = CALayer()
        canvas.frame = bounds

        let shadow = CALayer()
        shadow.frame = bounds
        shadow.shadowColor = CGColor(gray: 0, alpha: 1)
        shadow.shadowOpacity = 0.55
        shadow.shadowRadius = 24
        shadow.shadowOffset = CGSize(width: 12, height: -12)
        shadow.shadowPath = CGPath(rect: slot, transform: nil)
        let outsideSlot = CGMutablePath()
        outsideSlot.addRect(bounds)
        outsideSlot.addRect(slot)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = outsideSlot
        let shadowContainer = CALayer()
        shadowContainer.frame = bounds
        shadowContainer.addSublayer(shadow)
        shadowContainer.mask = mask
        canvas.addSublayer(shadowContainer)

        // Opacity keyframes in seconds; each window fades the default label
        // out and its own in (and back) over the dissolve.
        let dissolve = cameraDissolveSeconds
        func label(_ text: String, opacity points: [(seconds: Double, opacity: Double)]) -> CALayer {
            let layer = CALayer()
            if let image = cameraLabelImage(text) {
                layer.contents = image
                layer.frame = CGRect(
                    x: slot.minX, y: slot.maxY - Double(image.height),
                    width: Double(image.width), height: Double(image.height))
            }
            layer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = points.map(\.opacity)
            animation.keyTimes = points.map { NSNumber(value: min(1, max(0, $0.seconds / totalSeconds))) }
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.duration = totalSeconds
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            layer.add(animation, forKey: "visibility")
            return layer
        }

        var rearPoints: [(seconds: Double, opacity: Double)] = [(0, 1)]
        for window in windows {
            let start = window.range.start.seconds
            let end = window.range.end.seconds
            rearPoints += [(start, 1), (start + dissolve, 0), (end - dissolve, 0), (end, 1)]
            canvas.addSublayer(
                label(
                    window.override.displayLabel,
                    opacity: [
                        (0, 0), (start, 0), (start + dissolve, 1), (end - dissolve, 1), (end, 0),
                        (totalSeconds, 0),
                    ]))
        }
        rearPoints.append((totalSeconds, 1))
        canvas.addSublayer(label(CameraOverride.Camera.rear.defaultLabel, opacity: rearPoints))
        return canvas
    }

    /// The camera slot's label tag: `text` in yellow Helvetica Bold on a
    /// translucent black band, its ink centred vertically.
    static func cameraLabelImage(_ text: String) -> CGImage? {
        let font = NSFont.helveticaBold(size: cameraLabelFontSize)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(
                        cgColor: AnnotationRenderer.textColour) ?? .yellow,
                ]))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = Int((max(advance, ink.maxX) + 2 * cameraLabelPadding).rounded(.up))
        let height = cameraLabelHeight
        guard let context = try? LayerCompositor.bitmapContext(width: width, height: height)
        else { return nil }
        context.setFillColor(AnnotationRenderer.backgroundColour)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(
            x: cameraLabelPadding, y: (Double(height) - ink.height) / 2 - ink.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
