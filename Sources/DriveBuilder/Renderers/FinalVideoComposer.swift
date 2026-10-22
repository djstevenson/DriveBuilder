import AVFoundation
import AppKit
import Foundation
import QuartzCore

/// Seconds to skip at the start of each separately recorded component so
/// they play in sync: the cameras and the telemetry logger don't all start
/// recording at the same moment. Read from a `journey_segments` row
/// (`front_offset`, `rear_offset`, `telemetry_offset`, `left_offset`,
/// `right_offset`).
package struct StartOffsets: Sendable, Equatable {
    package var front: Double
    package var rear: Double
    package var telemetry: Double
    /// The optional side cameras: nil when the segment has no such view.
    package var left: Double?
    package var right: Double?

    package init(
        front: Double = 0, rear: Double = 0, telemetry: Double = 0, left: Double? = nil,
        right: Double? = nil
    ) {
        self.front = front
        self.rear = rear
        self.telemetry = telemetry
        self.left = left
        self.right = right
    }
}

/// Stitches the already-rendered clips into the final programme:
/// intro → route map → (drive footage with the rear-view inset and dials on
/// top) → outro, with a one-second cross-fade between each. The drive plays
/// the journey's segments one after another, dipping to black at each join
/// where something was cut out. The dials clip
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
    let outroURL: URL

    /// The drive's footage, segment by segment in playback order; never
    /// empty. dials.mov covers them all, already joined (see
    /// `TelemetryRecord.driveFrames`).
    var segments: [SegmentFootage]

    /// One segment's footage: what plays under the dials for its stretch of
    /// the drive.
    struct SegmentFootage {
        var frontURL: URL
        var rearURL: URL
        /// The optional side cameras' footage: nil when the segment has no
        /// such view. A side camera only appears in the camera slot during
        /// its `cameraOverrides` windows, in sync by skipping its own
        /// `startOffsets.left`/`.right`, so it only has to cover those
        /// windows - it doesn't limit the segment's length.
        var leftURL: URL?
        var rightURL: URL?
        /// Seconds skipped at the start of each source so the separately
        /// started recordings play in sync. The telemetry offset was
        /// already applied when dials.mov was rendered from the drive, so
        /// it isn't used here.
        var startOffsets = StartOffsets()
        /// The segment's length in seconds from its synced start: each of
        /// its sources must have at least this much left after its start
        /// offset, or the composition fails. Only the last segment may leave
        /// it nil, running for whichever of its sources (and the rest of
        /// dials.mov) is shortest, truncating the others to match.
        var length: Double?

        init(frontURL: URL, rearURL: URL) {
            self.frontURL = frontURL
            self.rearURL = rearURL
        }
    }

    /// Windows during which the camera slot (where the rear view sits,
    /// top-left) shows another camera, or the rear view with its own label.
    /// They mustn't overlap. A side camera pushes into the slot from its own
    /// side (and back out) over `cameraSlideSeconds`; the old label shrinks
    /// away as it starts, and the new one pops in once it lands.
    var cameraOverrides: [PlacedCameraOverride] = []

    /// A camera override placed on the drive segment: `start` and `end` are
    /// drive seconds (into the synced drive segment), found from the
    /// override's locations.
    struct PlacedCameraOverride: Sendable, Equatable {
        let camera: CameraOverride.Camera
        let start: Double
        let end: Double
        /// The label actually shown.
        let label: String
    }

    /// The camera slot's transition timings (see `CameraOverride`).
    static let cameraSlideSeconds = CameraOverride.slideSeconds
    static let cameraLabelPopSeconds = CameraOverride.labelPopSeconds
    static let cameraLabelHideSeconds = CameraOverride.labelHideSeconds
    static var minimumCameraWindowSeconds: Double { CameraOverride.minimumDuration }

    /// The camera slot's label: a tag in the slot's top-left corner, styled
    /// like the annotation banner (translucent black, yellow Helvetica).
    static let cameraLabelHeight = 52
    static let cameraLabelFontSize = 30.0
    static let cameraLabelPadding = 16.0

    /// Length of each cross-fade between clips.
    var crossFadeSeconds = defaultCrossFadeSeconds

    /// The cross-fade `JourneyRenderer` renders with, which Studio also
    /// assumes when working out where final.mov's drive segment starts.
    static let defaultCrossFadeSeconds = 1.0

    /// The gap the overlays keep from the frame's edges: the rear-view inset
    /// sits this far from the top and left, the dial column this far from
    /// the top, bottom, and right, and the annotation banners this far from
    /// the left and bottom.
    static let defaultEdgeInset = 20.0

    /// Gap between the frame's edges and the rear-view inset, dial column,
    /// and annotation banners (see `defaultEdgeInset`).
    var edgeInset = defaultEdgeInset

    /// How long the picture and sound take to fade to black at the end of
    /// one segment, and again to fade back in at the start of the next.
    var joinFadeSeconds = defaultJoinFadeSeconds
    static let defaultJoinFadeSeconds = 0.5

    /// Caps the drive segment (dials/footage/rear-view) to at most this many
    /// seconds, for a quick test render while checking sync — e.g. the first
    /// 30 seconds — rather than the whole journey. The intro and outro
    /// always play in full; `nil` renders the drive segment at full length.
    var maxDriveSegmentSeconds: Double?

    /// One rendered annotation banner (see `Annotations`) to composite over
    /// the drive segment.
    struct AnnotationClip {
        let url: URL
        /// Drive seconds (into the synced drive segment) at which the
        /// annotation should finish: when the track passes its end location.
        let endSeconds: Double
    }

    /// Annotations to composite over the drive segment, in the frame's
    /// bottom-left corner, each ending at its own `endSeconds`.
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
    }

    /// One segment's footage, loaded and placed on the final timeline.
    private struct PlacedSegment {
        /// Its index in `segments`.
        let index: Int
        let footage: SegmentFootage
        let front: Clip
        let rear: Clip
        /// Where in each source the segment's synced start lies.
        let frontSourceStart: CMTime
        let rearSourceStart: CMTime
        /// Where it starts in the final video, and how long it plays.
        let start: CMTime
        var duration: CMTime
        var end: CMTime { start + duration }
    }

    /// A camera override placed on the final timeline, within one segment.
    private struct CameraWindow {
        let override: PlacedCameraOverride
        let range: CMTimeRange
        /// The side camera filling the slot, and where in its source the
        /// window starts; nil for a relabelled rear view.
        let side: SideCamera?
        let sourceStart: CMTime
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
        let outro = try await loadClip(at: outroURL)

        let timescale: CMTimeScale = 600
        let fade = CMTime(seconds: crossFadeSeconds, preferredTimescale: timescale)
        let joinFade = CMTime(seconds: joinFadeSeconds, preferredTimescale: timescale)

        // The route map is the full-screen element, so it sets the frame
        // size; the narrower intro and outro are scaled to fit and centred,
        // the dial column is scaled to fit and right-aligned, the drive
        // footage fills the frame (cropping any overflow) as the backdrop,
        // and the camera slot shows the rear view at native size near the
        // top-left.
        let renderSize = routeMap.naturalSize

        // Timeline: each clip starts one fade-length before its predecessor
        // ends. The dials overlay, the camera slot, and the drive footage
        // beneath them run together through every segment.
        let introEnd = intro.duration
        let routeStart = introEnd - fade
        let routeEnd = routeStart + routeMap.duration
        let dialsStart = JourneyTimeline.driveSegmentStart(
            introDuration: intro.duration, routeMapDuration: routeMap.duration, crossFade: fade)

        let placed = try await placeSegments(
            dials: dials, dialsStart: dialsStart, timescale: timescale)
        guard let firstSegment = placed.first, let lastSegment = placed.last else {
            throw CompositionError(message: "The journey has no segments to play.")
        }
        let dialsSegmentDuration = lastSegment.end - dialsStart
        let dialsEnd = dialsStart + dialsSegmentDuration
        let outroStart = dialsEnd - fade
        let outroEnd = outroStart + outro.duration

        // Each join dips to black: the end of one segment fades out, the
        // start of the next fades in. Neither fade may run into the route
        // map's fade or the outro's.
        var joins: [CMTime] = []
        for segment in placed.dropFirst() {
            let join = segment.start
            if join - joinFade < routeEnd {
                throw CompositionError(
                    message: String(
                        format: "Segment %d starts %.1fs into the drive, too soon after the "
                            + "route map for its fade to black.",
                        segment.index + 1, (join - dialsStart).seconds))
            }
            if join + joinFade > outroStart {
                guard maxDriveSegmentSeconds == nil else { continue }
                throw CompositionError(
                    message: String(
                        format: "Segment %d is too short (%.1fs) to fade in before the outro.",
                        segment.index + 1, segment.duration.seconds))
            }
            joins.append(join)
        }
        let joinRamps = joins.flatMap { join in
            [
                AVVideoCompositionLayerInstruction.OpacityRamp(
                    timeRange: CMTimeRange(start: join - joinFade, end: join), start: 1, end: 0),
                AVVideoCompositionLayerInstruction.OpacityRamp(
                    timeRange: CMTimeRange(start: join, end: join + joinFade), start: 0, end: 1),
            ]
        }

        let cameraWindows = try await placeCameraOverrides(
            in: placed, visibleRange: CMTimeRange(start: routeEnd, end: outroStart),
            timescale: timescale)

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
        for camera in Set(cameraWindows.compactMap { $0.side == nil ? nil : $0.override.camera }) {
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
        // their own rather than sharing A; each segment's footage follows
        // straight on from the one before.
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: intro.duration),
            of: intro.track, at: .zero)
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: routeMap.duration),
            of: routeMap.track, at: routeStart)
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: dialsSegmentDuration),
            of: dials.track, at: dialsStart)
        for segment in placed {
            try footageTrack.insertTimeRange(
                CMTimeRange(start: segment.frontSourceStart, duration: segment.duration),
                of: segment.front.track, at: segment.start)
            try rearTrack.insertTimeRange(
                CMTimeRange(start: segment.rearSourceStart, duration: segment.duration),
                of: segment.rear.track, at: segment.start)
        }
        for window in cameraWindows {
            guard let side = window.side, let track = sideTracks[window.override.camera]
            else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: window.sourceStart, duration: window.range.duration),
                of: side.clip.track, at: window.range.start)
        }
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: outro.duration),
            of: outro.track, at: outroStart)

        // Each segment's front camera also provides its sound: its audio is
        // inserted in the same synced, truncated window as its picture,
        // fading in and out with the video cross-fades either side and
        // dipping with the picture at each join. The rest of the programme
        // stays silent.
        var audioMix: AVAudioMix?
        var frontAudio: [(segment: PlacedSegment, track: AVAssetTrack)] = []
        for segment in placed {
            if let track = try await segment.front.asset.loadTracks(withMediaType: .audio).first {
                frontAudio.append((segment, track))
            } else {
                print(
                    "final: \(segment.footage.frontURL.lastPathComponent) has no audio track; "
                        + "its segment will be silent.")
            }
        }
        if !frontAudio.isEmpty {
            guard
                let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw CompositionError(message: "Could not create composition tracks.")
            }
            for (segment, track) in frontAudio {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: segment.frontSourceStart, duration: segment.duration),
                    of: track, at: segment.start)
            }

            let fadeParameters = AVMutableAudioMixInputParameters(track: audioTrack)
            fadeParameters.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: dialsStart, end: routeEnd))
            for ramp in joinRamps {
                fadeParameters.setVolumeRamp(
                    fromStartVolume: Float(ramp.start), toEndVolume: Float(ramp.end),
                    timeRange: ramp.timeRange)
            }
            fadeParameters.setVolumeRamp(
                fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: outroStart, end: dialsEnd))
            let mix = AVMutableAudioMix()
            mix.inputParameters = [fadeParameters]
            audioMix = mix
        }

        // The camera slot: the rear view's frame, which every camera fills
        // (every segment's rear view is the same size; see `placeSegments`).
        let rearSize = firstSegment.rear.naturalSize
        let slotRect = CGRect(
            x: edgeInset, y: edgeInset, width: rearSize.width, height: rearSize.height)

        // Core Animation supplies a transparent synthetic track, composited
        // just above the camera slot: the slot's soft shadow (masked to
        // outside the slot, so it can't darken the picture) and its labels.
        let rearShadowTrackID: CMPersistentTrackID = 0x53484457
        let shadowCanvas = Self.cameraSlotOverlay(
            slotRect: slotRect, renderSize: renderSize,
            windows: cameraWindows.map { ($0.override, $0.range) },
            totalSeconds: outroEnd.seconds)
        let shadowAnimationTool = AVVideoCompositionCoreAnimationTool(
            additionalLayer: shadowCanvas, asTrackID: rearShadowTrackID)

        /// Where `clip` draws in the frame under `placement`.
        func placementTransform(for clip: Clip, _ placement: Placement) -> CGAffineTransform {
            switch placement {
            case .filling(let rect):
                let scale = max(
                    rect.width / clip.naturalSize.width, rect.height / clip.naturalSize.height)
                return CGAffineTransform(translationX: rect.minX, y: rect.minY)
                    .scaledBy(x: scale, y: scale)
            case .pinned(let x, let y):
                return CGAffineTransform(translationX: x, y: y)
            case .pinnedBottomLeading(let inset):
                return CGAffineTransform(
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
                return CGAffineTransform(
                    translationX: x,
                    y: (renderSize.height - clip.naturalSize.height * scale) / 2
                ).scaledBy(x: scale, y: scale)
            }
        }

        /// A layer showing `track` placed as `placement`, fading by
        /// `opacityRamps` (in time order). `laterClips` are the clips a
        /// footage track moves on to at each later segment's start, each
        /// placed by its own size and orientation.
        func layerInstruction(
            track: AVCompositionTrack, clip: Clip,
            placement: Placement = .fitCentred,
            opacityRamps: [AVVideoCompositionLayerInstruction.OpacityRamp] = [],
            slide: (transforms: [AVVideoCompositionLayerInstruction.TransformRamp],
                crops: [AVVideoCompositionLayerInstruction.CropRectangleRamp]) = ([], []),
            laterClips: [(start: CMTime, clip: Clip)] = []
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: track)
            // Un-rotate the source's own encoded orientation first, then
            // place it in the frame; for our own rendered clips this
            // transform is always identity, so it's a no-op.
            configuration.setTransform(
                clip.preferredTransform.concatenating(placementTransform(for: clip, placement)),
                at: .zero)
            for later in laterClips {
                configuration.setTransform(
                    later.clip.preferredTransform.concatenating(
                        placementTransform(for: later.clip, placement)),
                    at: later.start)
            }
            for ramp in opacityRamps {
                configuration.addOpacityRamp(ramp)
            }
            // A sliding tile's motion: absolute transforms (after the
            // source's own orientation) and crops, in time order.
            for ramp in slide.transforms {
                configuration.addTransformRamp(
                    .init(
                        timeRange: ramp.timeRange,
                        start: clip.preferredTransform.concatenating(ramp.start),
                        end: clip.preferredTransform.concatenating(ramp.end)))
            }
            for ramp in slide.crops {
                configuration.addCropRectangleRamp(ramp)
            }
            return AVVideoCompositionLayerInstruction(configuration: configuration)
        }

        // The footage tracks move from one segment's clips to the next's.
        let laterFronts = placed.dropFirst().map { (start: $0.start, clip: $0.front) }
        let laterRears = placed.dropFirst().map { (start: $0.start, clip: $0.rear) }

        // The pushes, for each side-camera window: the side camera in from
        // its own side and back out, the rear view out the other way and
        // back. The rear view's ramps run across the whole timeline.
        let slideDuration = CMTime(seconds: Self.cameraSlideSeconds, preferredTimescale: timescale)
        var rearSlide:
            (transforms: [AVVideoCompositionLayerInstruction.TransformRamp],
             crops: [AVVideoCompositionLayerInstruction.CropRectangleRamp]) = ([], [])
        var sideSlides:
            [(transforms: [AVVideoCompositionLayerInstruction.TransformRamp],
              crops: [AVVideoCompositionLayerInstruction.CropRectangleRamp])] = []
        for window in cameraWindows {
            guard let side = window.side else {
                sideSlides.append(([], []))
                continue
            }
            // The left camera arrives from the left (pushing the rear view
            // right); the right camera from the right.
            let direction: Double = window.override.camera == .left ? -1 : 1
            let width = slotRect.width
            let entry = CMTimeRange(start: window.range.start, duration: slideDuration)
            let exit = CMTimeRange(start: window.range.end - slideDuration, end: window.range.end)
            let sideIn = Self.slideRamps(
                clipSize: side.clip.naturalSize, slot: slotRect, over: entry,
                from: direction * width, to: 0, timescale: timescale)
            let sideOut = Self.slideRamps(
                clipSize: side.clip.naturalSize, slot: slotRect, over: exit,
                from: 0, to: direction * width, timescale: timescale)
            sideSlides.append(
                (sideIn.transforms + sideOut.transforms, sideIn.crops + sideOut.crops))
            let rearOut = Self.slideRamps(
                clipSize: rearSize, slot: slotRect, over: entry,
                from: 0, to: -direction * width, timescale: timescale)
            let rearIn = Self.slideRamps(
                clipSize: rearSize, slot: slotRect, over: exit,
                from: -direction * width, to: 0, timescale: timescale)
            rearSlide.transforms += rearOut.transforms + rearIn.transforms
            rearSlide.crops += rearOut.crops + rearIn.crops
        }

        func shadowLayerInstruction(
            opacityRamps: [AVVideoCompositionLayerInstruction.OpacityRamp] = []
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                trackID: rearShadowTrackID)
            for ramp in opacityRamps {
                configuration.addOpacityRamp(ramp)
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
                    opacityRamps: [
                        .init(
                            timeRange: CMTimeRange(start: routeStart, end: introEnd),
                            start: 1, end: 0)
                    ]),
                layerInstruction(track: trackB, clip: routeMap),
            ])

        // Route map alone.
        addInstruction(
            from: introEnd, to: dialsStart,
            layers: [layerInstruction(track: trackB, clip: routeMap)])

        let dialsPlacement = Placement.fitTrailing(inset: edgeInset)
        let rearPlacement = Placement.pinned(x: slotRect.minX, y: slotRect.minY)

        // The drive's layers, front to back: the dial column, the Core
        // Animation track (the slot's shadow and labels) just above the
        // slot, the rear view, and the drive footage. All dip to black
        // together at each join, then fade by `ramps`.
        func driveLayers(
            fading ramps: [AVVideoCompositionLayerInstruction.OpacityRamp] = []
        ) -> [AVVideoCompositionLayerInstruction] {
            let fades = joinRamps + ramps
            return [
                layerInstruction(
                    track: trackA, clip: dials, placement: dialsPlacement, opacityRamps: fades),
                shadowLayerInstruction(opacityRamps: fades),
                layerInstruction(
                    track: rearTrack, clip: firstSegment.rear, placement: rearPlacement,
                    opacityRamps: fades, slide: rearSlide, laterClips: laterRears),
                layerInstruction(
                    track: footageTrack, clip: firstSegment.front, placement: .fill,
                    opacityRamps: fades, laterClips: laterFronts),
            ]
        }

        // Route map fades out over the drive.
        addInstruction(
            from: dialsStart, to: routeEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: routeMap,
                    opacityRamps: [
                        .init(
                            timeRange: CMTimeRange(start: dialsStart, end: routeEnd),
                            start: 1, end: 0)
                    ])
            ] + driveLayers())

        // The drive alone.
        addInstruction(from: routeEnd, to: outroStart, layers: driveLayers())

        // The drive fades out while the outro fades in.
        addInstruction(
            from: outroStart, to: dialsEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: outro,
                    opacityRamps: [
                        .init(
                            timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                            start: 0, end: 1)
                    ])
            ]
                + driveLayers(
                    fading: [
                        .init(
                            timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                            start: 1, end: 0)
                    ]))

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

        // Each side-camera window's tile sits directly above the rear view
        // (below the slot's labels), pushing in and out, and dipping with
        // the rest of the picture if its segment ends.
        for (window, slide) in zip(cameraWindows, sideSlides) {
            guard let side = window.side, let track = sideTracks[window.override.camera]
            else { continue }
            insertLayer(
                layerInstruction(
                    track: track, clip: side.clip, placement: .filling(slotRect),
                    opacityRamps: joinRamps, slide: slide),
                over: window.range
            ) { layers in
                layers.firstIndex { $0.trackID == rearTrack.trackID } ?? 0
            }
        }

        // Annotations composite over the drive segment, in the bottom-left
        // corner (the banner's own width stops it a grid gap short of the
        // dial column, whose bottom map also finishes on the bottom edge), each
        // ending when the track passes its end location and playing through
        // its own built-in opening/scrolling/closing animation, so it only
        // fades if it overlaps a join's dip to black.
        for annotationClip in annotationClips {
            let clip = try await loadClip(at: annotationClip.url)
            let end =
                dialsStart + CMTime(seconds: annotationClip.endSeconds, preferredTimescale: timescale)
            let start = end - clip.duration
            guard start >= dialsStart, end <= dialsEnd else {
                print(
                    String(
                        format: "final: skipping %@ — it doesn't fall within the drive "
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
                layerInstruction(
                    track: annotationTrack, clip: clip,
                    placement: .pinnedBottomLeading(inset: edgeInset), opacityRamps: joinRamps),
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

    /// Loads each segment's front and rear footage and places the segments
    /// one after another from `dialsStart`. Throws for a start offset that
    /// skips a whole clip, a length a source can't cover, a missing length
    /// on any segment but the last, rear views of different sizes (the
    /// camera slot is the rear view's frame), or dials.mov falling short.
    ///
    /// With `maxDriveSegmentSeconds`, only the drive up to the cap is
    /// placed: segments starting past it are skipped unchecked (a quick
    /// preview's dials.mov doesn't reach them), and the one it falls in
    /// stops there.
    private func placeSegments(
        dials: Clip, dialsStart: CMTime, timescale: CMTimeScale
    ) async throws -> [PlacedSegment] {
        func time(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: timescale)
        }
        let capEnd = maxDriveSegmentSeconds.map { dialsStart + time($0) }
        var placed: [PlacedSegment] = []
        var start = dialsStart
        for (index, footage) in segments.enumerated() {
            if let capEnd, start >= capEnd { break }
            let isLast = index == segments.count - 1
            let name = segments.count > 1 ? "Segment \(index + 1)'s" : "The journey's"
            let front = try await loadClip(at: footage.frontURL)
            let rear = try await loadClip(at: footage.rearURL)
            if let first = placed.first, rear.naturalSize != first.rear.naturalSize {
                throw CompositionError(
                    message: "\(footage.rearURL.lastPathComponent) is "
                        + "\(Int(rear.naturalSize.width))x\(Int(rear.naturalSize.height)), but "
                        + "\(first.footage.rearURL.lastPathComponent) is "
                        + "\(Int(first.rear.naturalSize.width))x\(Int(first.rear.naturalSize.height)); "
                        + "every segment's rear view must be the same size.")
            }

            // The sources were recorded separately, so each skips its own
            // start offset to bring them into sync; what competes for
            // "shortest" below is the remainder after that skip. The last
            // segment also has to fit in what's left of dials.mov.
            let frontSourceStart = time(footage.startOffsets.front)
            let rearSourceStart = time(footage.startOffsets.rear)
            var sources = [
                (footage.frontURL.lastPathComponent, front.duration - frontSourceStart),
                (footage.rearURL.lastPathComponent, rear.duration - rearSourceStart),
            ]
            if let empty = sources.first(where: { $0.1 <= .zero }) {
                throw CompositionError(
                    message: "\(name) start offset for \(empty.0) skips the whole clip.")
            }
            // A length-less last segment runs until dials.mov ends too; a
            // set length is checked against dials.mov once the drive's
            // total (after any cap) is known, below.
            if isLast, footage.length == nil {
                sources.append(("dials.mov", dials.duration - (start - dialsStart)))
            }

            var duration: CMTime
            if let length = footage.length {
                if let short = sources.first(where: { $0.1 < time(length) }) {
                    throw CompositionError(
                        message: String(
                            format: "%@ length is %.1fs, but %@ only has %.1fs after its "
                                + "start offset.",
                            name, length, short.0, short.1.seconds))
                }
                print(String(format: "final: %@ length set to %.1fs.", name.lowercased(), length))
                duration = time(length)
            } else {
                guard isLast else {
                    throw CompositionError(
                        message: "Segment \(index + 1) has no length; only the last segment "
                            + "may run for as long as its sources last.")
                }
                duration = sources.map(\.1).min()!
                if sources.contains(where: { $0.1 != duration }) {
                    let shortest = sources.min { $0.1 < $1.1 }!.0
                    print(
                        "final: \(shortest) is the shortest of "
                            + sources.map(\.0).joined(separator: "/")
                            + " after start offsets; truncating the others to match.")
                }
            }
            guard duration > .zero else {
                throw CompositionError(
                    message: "dials.mov ends before segment \(index + 1) starts; render the "
                        + "dials again.")
            }
            if let capEnd, start + duration > capEnd {
                print(
                    String(
                        format: "final: capping the drive segment to %.1fs for a test render.",
                        (capEnd - dialsStart).seconds))
                duration = capEnd - start
            }

            let offsets = footage.startOffsets
            var descriptions = [
                String(format: "front %.1fs", offsets.front),
                String(format: "rear %.1fs", offsets.rear),
            ]
            if let left = offsets.left { descriptions.append(String(format: "left %.1fs", left)) }
            if let right = offsets.right {
                descriptions.append(String(format: "right %.1fs", right))
            }
            print(
                "final: \(name.lowercased()) start offsets "
                    + "\(descriptions.joined(separator: ", ")).")

            placed.append(
                PlacedSegment(
                    index: index, footage: footage, front: front, rear: rear,
                    frontSourceStart: frontSourceStart, rearSourceStart: rearSourceStart,
                    start: start, duration: duration))
            start = start + duration
        }

        let total = start - dialsStart
        if dials.duration < total {
            throw CompositionError(
                message: String(
                    format: "dials.mov is %.1fs, but the drive's segments run for %.1fs; "
                        + "render the dials again.",
                    dials.duration.seconds, total.seconds))
        }
        return placed
    }

    /// Validates `cameraOverrides` and places them on the final timeline:
    /// drive seconds become final-video time, clamped to
    /// `visibleRange` (after the route map, before the outro). Throws for a
    /// window that's empty, overlaps another, spans a join between
    /// segments, uses a camera its segment doesn't have, or runs past the
    /// end of that camera's video.
    private func placeCameraOverrides(
        in segments: [PlacedSegment], visibleRange: CMTimeRange, timescale: CMTimeScale
    ) async throws -> [CameraWindow] {
        func time(_ seconds: Double) -> String {
            let total = max(0, seconds)
            return String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
        }
        func describe(_ override: PlacedCameraOverride) -> String {
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

        guard let dialsStart = segments.first?.start else { return [] }
        let minimum = CMTime(
            seconds: Self.minimumCameraWindowSeconds, preferredTimescale: timescale)
        var clips: [URL: Clip] = [:]
        var windows: [CameraWindow] = []
        for override in overrides {
            func finalTime(_ driveSeconds: Double) -> CMTime {
                dialsStart + CMTime(seconds: driveSeconds, preferredTimescale: timescale)
            }
            let start = max(finalTime(override.start), visibleRange.start)
            let end = min(finalTime(override.end), visibleRange.end)
            let segment = segments.last { $0.start <= start } ?? segments[0]

            // A side camera comes from the segment's own footage.
            var side: SideCamera?
            if override.camera != .rear {
                let offsets = segment.footage.startOffsets
                let (url, offset) =
                    override.camera == .left
                    ? (segment.footage.leftURL, offsets.left)
                    : (segment.footage.rightURL, offsets.right)
                guard let url, offset != nil else {
                    throw CompositionError(
                        message: "\(describe(override)) needs the \(override.camera.rawValue) "
                            + "camera, but its segment has no \(override.camera.rawValue)_offset.")
                }
                if clips[url] == nil { clips[url] = try await loadClip(at: url) }
                side = clips[url].map { SideCamera(url: url, clip: $0) }
            }

            guard end - start >= minimum else {
                print(
                    String(
                        format: "final: skipping %@; less than %.2fs of it falls within the drive "
                            + "segment, too short for the camera to push in and out.",
                        describe(override).lowercased(), Self.minimumCameraWindowSeconds))
                continue
            }
            if end > segment.end {
                throw CompositionError(
                    message: "\(describe(override)) runs across the join between segments "
                        + "\(segment.index + 1) and \(segment.index + 2); split it into one "
                        + "override for each segment.")
            }

            var sourceStart = CMTime.zero
            if let side {
                let offsets = segment.footage.startOffsets
                let offset = (override.camera == .left ? offsets.left : offsets.right) ?? 0
                sourceStart =
                    CMTime(seconds: offset, preferredTimescale: timescale) + (start - segment.start)
                if sourceStart + (end - start) > side.clip.duration {
                    throw CompositionError(
                        message: "\(describe(override)) runs past the end of "
                            + "\(side.url.lastPathComponent).")
                }
            }
            windows.append(
                CameraWindow(
                    override: override, range: CMTimeRange(start: start, end: end), side: side,
                    sourceStart: sourceStart))
        }
        return windows
    }

    /// The Core Animation layer composited just above the camera slot: the
    /// slot's drop shadow, masked to outside the slot, and the slot's
    /// labels - the rear view's by default, each override's during its
    /// window - dissolving with the cameras. Built from plain values, so the
    /// layers can be handed to the animation tool.
    private static func cameraSlotOverlay(
        slotRect: CGRect, renderSize: CGSize,
        windows: [(override: PlacedCameraOverride, range: CMTimeRange)], totalSeconds: Double
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

        // Each label scales from its top-left corner: popping in with a slight
        // overshoot, shrinking away to nothing. Keyframes in seconds,
        // sampled every frame so the easing survives linear interpolation.
        func label(_ text: String, scale points: [(seconds: Double, scale: Double)]) -> CALayer {
            let layer = CALayer()
            if let image = cameraLabelImage(text) {
                layer.contents = image
                layer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                layer.anchorPoint = CGPoint(x: 0, y: 1)
                layer.position = CGPoint(x: slot.minX, y: slot.maxY)
            }
            layer.transform = CATransform3DMakeScale(0, 0, 1)
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = points.map(\.scale)
            animation.keyTimes = points.map {
                NSNumber(value: min(1, max(0, $0.seconds / totalSeconds)))
            }
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.duration = totalSeconds
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            layer.add(animation, forKey: "visibility")
            return layer
        }
        let frame = 1.0 / 30
        func pop(at start: Double) -> [(seconds: Double, scale: Double)] {
            stride(from: 0, through: cameraLabelPopSeconds + frame / 2, by: frame).map {
                (start + $0, RouteMapRenderer.popScale($0 / cameraLabelPopSeconds))
            }
        }
        func hide(at start: Double) -> [(seconds: Double, scale: Double)] {
            stride(from: 0, through: cameraLabelHideSeconds + frame / 2, by: frame).map {
                let p = min(1, $0 / cameraLabelHideSeconds)
                return (start + $0, 1 - p * p)  // ease-in: shrinks faster as it goes
            }
        }

        // A side camera's label waits for the push to land, and goes as the
        // push back out begins; a relabelled rear view swaps labels at once.
        var hiddenSpans: [(start: Double, end: Double)] = []
        for window in windows {
            let start = window.range.start.seconds
            let end = window.range.end.seconds
            let isSide = window.override.camera != .rear
            let labelIn = start + (isSide ? cameraSlideSeconds : cameraLabelHideSeconds)
            let labelOut = end - (isSide ? cameraSlideSeconds : cameraLabelHideSeconds)
            canvas.addSublayer(
                label(
                    window.override.label,
                    scale: [(0, 0)] + pop(at: labelIn) + hide(at: labelOut) + [(totalSeconds, 0)]))
            hiddenSpans.append((start, end))
        }

        // The rear view's label: away for each window, back once it's over -
        // unless the next window follows too closely for it to pop back in
        // and shrink away again.
        var merged: [(start: Double, end: Double)] = []
        for span in hiddenSpans {
            if let last = merged.last,
                span.start - last.end < cameraLabelPopSeconds + cameraLabelHideSeconds
            {
                merged[merged.count - 1].end = span.end
            } else {
                merged.append(span)
            }
        }
        var rearPoints: [(seconds: Double, scale: Double)] = [(0, 1)]
        for span in merged {
            rearPoints += hide(at: span.start) + pop(at: span.end)
        }
        rearPoints.append((totalSeconds, 1))
        canvas.addSublayer(label(CameraOverride.Camera.rear.defaultLabel, scale: rearPoints))
        return canvas
    }

    /// Ramps moving a tile horizontally through the camera slot over
    /// `range`, from `startOffset` to `endOffset` pixels right of its home
    /// position, eased in and out. The tile fills the slot's height; it's
    /// cropped to the part inside the slot, so it never shows beyond it.
    /// AVFoundation ramps are linear, so the easing is built from one ramp
    /// per frame.
    static func slideRamps(
        clipSize: CGSize, slot: CGRect, over range: CMTimeRange,
        from startOffset: Double, to endOffset: Double, timescale: CMTimeScale
    ) -> (
        transforms: [AVVideoCompositionLayerInstruction.TransformRamp],
        crops: [AVVideoCompositionLayerInstruction.CropRectangleRamp]
    ) {
        let steps = max(1, Int((range.duration.seconds * 30).rounded()))
        func offset(_ step: Int) -> Double {
            let p = Double(step) / Double(steps)
            let eased = p * p * (3 - 2 * p)
            return startOffset + (endOffset - startOffset) * eased
        }
        func time(_ step: Int) -> CMTime {
            range.start
                + CMTime(
                    seconds: range.duration.seconds * Double(step) / Double(steps),
                    preferredTimescale: timescale)
        }
        var transforms: [AVVideoCompositionLayerInstruction.TransformRamp] = []
        var crops: [AVVideoCompositionLayerInstruction.CropRectangleRamp] = []
        for step in 0..<steps {
            let span = CMTimeRange(start: time(step), end: time(step + 1))
            let from = slidingTile(clipSize: clipSize, slot: slot, offset: offset(step))
            let to = slidingTile(clipSize: clipSize, slot: slot, offset: offset(step + 1))
            transforms.append(.init(timeRange: span, start: from.transform, end: to.transform))
            crops.append(.init(timeRange: span, start: from.crop, end: to.crop))
        }
        return (transforms, crops)
    }

    /// Where a tile filling the camera slot draws when it's `offset`
    /// pixels right of its home position: its transform, and the crop (in
    /// the clip's own pixels) that keeps only the part inside the slot.
    static func slidingTile(
        clipSize: CGSize, slot: CGRect, offset: Double
    ) -> (transform: CGAffineTransform, crop: CGRect) {
        let scale = max(slot.width / clipSize.width, slot.height / clipSize.height)
        let left = slot.minX + offset
        let visibleMin = max(slot.minX, left)
        let visibleMax = min(slot.maxX, left + clipSize.width * scale)
        // Never empty: a sliver at the slot's edge stays hidden beneath the
        // other camera, and a zero-width crop isn't well defined.
        let visibleWidth = max(1, visibleMax - visibleMin)
        let cropX = min(visibleMin - left, clipSize.width * scale - visibleWidth)
        return (
            CGAffineTransform(translationX: left, y: slot.minY).scaledBy(x: scale, y: scale),
            CGRect(
                x: max(0, cropX) / scale, y: 0,
                width: visibleWidth / scale, height: slot.height / scale)
        )
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
