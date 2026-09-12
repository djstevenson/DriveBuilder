import AVFoundation
import Foundation

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
        let dialsSegmentDuration = driveClips.map(\.1).min()!
        if driveClips.contains(where: { $0.1 != dialsSegmentDuration }) {
            let shortest = driveClips.min { $0.1 < $1.1 }!.0
            print(
                "final: \(shortest) is the shortest of dials.mov/front.mov/rear.mov "
                    + "after start offsets; truncating the others to match.")
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

        // The route map is the full-screen element, so it sets the frame
        // size; the narrower intro and outro are scaled to fit and centred,
        // the dial column is scaled to fit and right-aligned, the drive
        // footage fills the frame (cropping any overflow) as the backdrop,
        // and the rear-view inset sits at native size near the top-left.
        let renderSize = routeMap.naturalSize

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

        var instructions: [AVVideoCompositionInstruction] = []
        func addInstruction(
            from start: CMTime, to end: CMTime,
            layers: [AVVideoCompositionLayerInstruction]
        ) {
            instructions.append(
                AVVideoCompositionInstruction(
                    configuration: .init(
                        layerInstructions: layers,
                        timeRange: CMTimeRange(start: start, end: end))))
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
                layerInstruction(track: footageTrack, clip: frontFootage, placement: .fill),
            ])

        // Drive footage, rear-view inset, and dial column alone.
        addInstruction(
            from: routeEnd, to: outroStart,
            layers: [
                layerInstruction(track: trackA, clip: dials, placement: .fitTrailing),
                layerInstruction(track: rearTrack, clip: rearFootage, placement: rearPlacement),
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
