import AVFoundation
import Foundation
import QuartzCore

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

    /// Length of each cross-fade between clips.
    var crossFadeSeconds: Double = 1.0

    /// Gap between the frame's top-left corner and the rear-view inset.
    var rearFootageInset: Double = 20.0

    /// Seconds skipped at the start of each drive-segment source (from the
    /// journey's main.json) so the separately started recordings play in
    /// sync; the telemetry offset applies to the dials clip rendered from it.
    var startOffsets = MainConfig.StartOffsets()

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
        /// annotation should finish. This is main.json's own "offset", not
        /// yet adjusted to the synced drive-segment timeline.
        let rawEndOffsetSeconds: Double
    }

    /// Annotations to composite over the drive segment, bottom-aligned,
    /// each ending at its own `rawEndOffsetSeconds`.
    var annotationClips: [AnnotationClip] = []

    var framesPerSecond: Int32 = 30

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
        /// Scaled to fit entirely within the frame, flush with the right edge.
        case fitTrailing
        /// Scaled to fill the frame, centred, cropping any overflow.
        case fill
        /// Native size, its top-left corner at the given frame offset.
        case pinned(x: Double, y: Double)
        /// Scaled to match the frame's width (keeping aspect), flush with
        /// the bottom edge — for the annotation banners, whose canvases
        /// carry their own bottom inset and rise-from-below animation.
        case fitWidthBottom
    }

    /// One instruction still under construction: a time range and its
    /// active layers, kept as plain data (rather than the immutable
    /// `AVVideoCompositionInstruction`) so annotations can later split a
    /// range and splice their own layer into just the overlapping piece.
    private struct Phase {
        var range: CMTimeRange
        var layers: [AVVideoCompositionLayerInstruction]
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

        // The drive-segment sources were recorded separately, so each skips
        // its own start offset to bring the three into sync; what competes
        // for "shortest" below is the remainder after that skip.
        let dialsSourceStart = CMTime(seconds: startOffsets.telemetry, preferredTimescale: timescale)
        let frontSourceStart = CMTime(seconds: startOffsets.front, preferredTimescale: timescale)
        let rearSourceStart = CMTime(seconds: startOffsets.rear, preferredTimescale: timescale)
        if startOffsets.front != 0 || startOffsets.rear != 0 || startOffsets.telemetry != 0 {
            print(
                String(
                    format: "final: start offsets front %.1fs, rear %.1fs, telemetry %.1fs.",
                    startOffsets.front, startOffsets.rear, startOffsets.telemetry))
        }

        // Timeline: each clip starts one fade-length before its predecessor
        // ends. The dials overlay, the rear-view inset, and the drive footage
        // beneath them run together for whichever of the three is shortest.
        let introEnd = intro.duration
        let routeStart = introEnd - fade
        let routeEnd = routeStart + routeMap.duration
        let dialsStart = routeEnd - fade
        let driveClips = [
            ("dials.mov", dials.duration - dialsSourceStart),
            ("front.mov", frontFootage.duration - frontSourceStart),
            ("rear.mov", rearFootage.duration - rearSourceStart),
        ]
        if let empty = driveClips.first(where: { $0.1 <= .zero }) {
            throw CompositionError(
                message: "The main.json start offset for \(empty.0) skips the whole clip.")
        }
        var dialsSegmentDuration = driveClips.map(\.1).min()!
        if driveClips.contains(where: { $0.1 != dialsSegmentDuration }) {
            let shortest = driveClips.min { $0.1 < $1.1 }!.0
            print(
                "final: \(shortest) is the shortest of dials.mov/front.mov/rear.mov "
                    + "after start offsets; truncating the others to match.")
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

        // Adjacent clips sit on different tracks so they can overlap during
        // the fades, alternating A, B, A, B along the timeline. The drive
        // footage and the rear-view inset run underneath/alongside the dials
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

        // The route map is the full-screen element, so it sets the frame
        // size; the narrower intro and outro are scaled to fit and centred,
        // the dial column is scaled to fit and right-aligned, the drive
        // footage fills the frame (cropping any overflow) as the backdrop,
        // and the rear-view inset sits at native size near the top-left.
        let renderSize = routeMap.naturalSize

        // Core Animation supplies a transparent synthetic track containing a
        // soft shadow shaped to the rear inset. The footage is composited
        // immediately above it.
        let rearShadowTrackID: CMPersistentTrackID = 0x53484457
        let shadowCanvas = CALayer()
        shadowCanvas.frame = CGRect(origin: .zero, size: renderSize)
        let rearShadow = CALayer()
        rearShadow.frame = CGRect(
            x: rearFootageInset,
            y: renderSize.height - rearFootageInset - rearFootage.naturalSize.height,
            width: rearFootage.naturalSize.width,
            height: rearFootage.naturalSize.height)
        rearShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        rearShadow.shadowOpacity = 0.55
        rearShadow.shadowRadius = 24
        rearShadow.shadowOffset = CGSize(width: 12, height: -12)
        rearShadow.shadowPath = CGPath(rect: rearShadow.bounds, transform: nil)
        shadowCanvas.addSublayer(rearShadow)
        let shadowAnimationTool = AVVideoCompositionCoreAnimationTool(
            additionalLayer: shadowCanvas, asTrackID: rearShadowTrackID)

        func layerInstruction(
            track: AVCompositionTrack, clip: Clip,
            placement: Placement = .fitCentred,
            opacityRamp: AVVideoCompositionLayerInstruction.OpacityRamp? = nil
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: track)
            let placementTransform: CGAffineTransform
            switch placement {
            case .pinned(let x, let y):
                placementTransform = CGAffineTransform(translationX: x, y: y)
            case .fitWidthBottom:
                let scale = renderSize.width / clip.naturalSize.width
                let scaledHeight = clip.naturalSize.height * scale
                placementTransform = CGAffineTransform(
                    translationX: 0, y: renderSize.height - scaledHeight
                ).scaledBy(x: scale, y: scale)
            case .fitCentred, .fitTrailing, .fill:
                let scale: Double
                if case .fill = placement {
                    scale = max(
                        renderSize.width / clip.naturalSize.width,
                        renderSize.height / clip.naturalSize.height)
                } else {
                    scale = min(
                        renderSize.width / clip.naturalSize.width,
                        renderSize.height / clip.naturalSize.height)
                }
                let scaledWidth = clip.naturalSize.width * scale
                let x =
                    if case .fitTrailing = placement {
                        renderSize.width - scaledWidth
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

        let rearPlacement = Placement.pinned(x: rearFootageInset, y: rearFootageInset)

        // Route map fades out over the drive footage, rear-view inset, and
        // dial column.
        addInstruction(
            from: dialsStart, to: routeEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: routeMap,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: dialsStart, end: routeEnd),
                        start: 1, end: 0)),
                layerInstruction(track: trackA, clip: dials, placement: .fitTrailing),
                layerInstruction(track: rearTrack, clip: rearFootage, placement: rearPlacement),
                shadowLayerInstruction(),
                layerInstruction(track: footageTrack, clip: frontFootage, placement: .fill),
            ])

        // Drive footage, rear-view inset, and dial column alone.
        addInstruction(
            from: routeEnd, to: outroStart,
            layers: [
                layerInstruction(track: trackA, clip: dials, placement: .fitTrailing),
                layerInstruction(track: rearTrack, clip: rearFootage, placement: rearPlacement),
                shadowLayerInstruction(),
                layerInstruction(track: footageTrack, clip: frontFootage, placement: .fill),
            ])

        // Drive footage, rear-view inset, and dial column fade out together
        // while the outro fades in.
        addInstruction(
            from: outroStart, to: dialsEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: outro,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 0, end: 1)),
                layerInstruction(
                    track: trackA, clip: dials, placement: .fitTrailing,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 1, end: 0)),
                layerInstruction(
                    track: rearTrack, clip: rearFootage, placement: rearPlacement,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 1, end: 0)),
                shadowLayerInstruction(
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 1, end: 0)),
                layerInstruction(
                    track: footageTrack, clip: frontFootage, placement: .fill,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: dialsEnd),
                        start: 1, end: 0)),
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
                result.append(
                    Phase(range: CMTimeRange(start: start, end: end), layers: [layer] + phase.layers))
                if end < phase.range.end {
                    result.append(
                        Phase(range: CMTimeRange(start: end, end: phase.range.end), layers: phase.layers))
                }
            }
            phases = result
        }

        // Annotations composite over the drive segment, bottom-aligned, each
        // ending at its own offset (from main.json, adjusted here from
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
                layerInstruction(track: annotationTrack, clip: clip, placement: .fitWidthBottom),
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
        // periodically while it runs.
        let states = session.states(updateInterval: 15)
        let monitor = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    print(
                        String(
                            format: "final: exporting, %.0f%% complete",
                            progress.fractionCompleted * 100))
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mov)

        let elapsed = started.duration(to: .now)
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            String(
                format: "final: wrote %.1fs in %.1fs to %@",
                outroEnd.seconds, seconds, url.path(percentEncoded: false)))
    }
}
