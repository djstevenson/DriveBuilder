import AVFoundation
import Foundation

/// Stitches the already-rendered clips into the final programme:
/// intro → route map → drive-footage placeholder → outro, with a
/// one-second cross-fade between each. The placeholder is a plain
/// black screen until the real drive footage is wired in.
struct FinalVideoComposer {
    let introURL: URL
    let routeMapURL: URL
    let outroURL: URL

    /// Length of each cross-fade between clips.
    var crossFadeSeconds: Double = 1.0

    /// Length of the black stand-in for the drive footage, including the
    /// cross-fades at either end.
    var placeholderSeconds: Double = 10.0

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

    private struct Clip {
        // An AVAssetTrack doesn't retain its asset, so the clip must keep
        // the asset alive itself or later track operations fail with -11800.
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        let naturalSize: CGSize
    }

    private func loadClip(at url: URL) async throws -> Clip {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw MissingClipError(url: url)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionError(message: "No video track in \(url.lastPathComponent).")
        }
        let (timeRange, naturalSize) = try await track.load(.timeRange, .naturalSize)
        return Clip(
            asset: asset, track: track,
            duration: timeRange.duration, naturalSize: naturalSize)
    }

    func writeMovie(to url: URL) async throws {
        let started = ContinuousClock.now

        let intro = try await loadClip(at: introURL)
        let routeMap = try await loadClip(at: routeMapURL)
        let outro = try await loadClip(at: outroURL)

        let timescale: CMTimeScale = 600
        let fade = CMTime(seconds: crossFadeSeconds, preferredTimescale: timescale)
        let placeholder = CMTime(seconds: placeholderSeconds, preferredTimescale: timescale)

        // Timeline: each clip starts one fade-length before its predecessor
        // ends. The placeholder has no track of its own; it's just the
        // composition's black background, with the route map fading out over
        // its first second and the outro fading in over its last.
        let introEnd = intro.duration
        let routeStart = introEnd - fade
        let routeEnd = routeStart + routeMap.duration
        let blackEnd = routeEnd - fade + placeholder
        let outroStart = blackEnd - fade
        let outroEnd = outroStart + outro.duration

        let composition = AVMutableComposition()
        guard
            let trackA = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let trackB = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw CompositionError(message: "Could not create composition tracks.")
        }

        // Adjacent clips sit on different tracks so they can overlap during
        // the fades; the intro and outro never overlap each other, so they
        // share track A.
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: intro.duration),
            of: intro.track, at: .zero)
        try trackB.insertTimeRange(
            CMTimeRange(start: .zero, duration: routeMap.duration),
            of: routeMap.track, at: routeStart)
        try trackA.insertTimeRange(
            CMTimeRange(start: .zero, duration: outro.duration),
            of: outro.track, at: outroStart)

        // The route map is the full-screen element, so it sets the frame
        // size; the narrower intro and outro are scaled to fit and centred.
        let renderSize = routeMap.naturalSize

        func layerInstruction(
            track: AVCompositionTrack, clip: Clip,
            opacityRamp: AVVideoCompositionLayerInstruction.OpacityRamp? = nil
        ) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(
                assetTrack: track)
            let scale = min(
                renderSize.width / clip.naturalSize.width,
                renderSize.height / clip.naturalSize.height)
            let transform = CGAffineTransform(
                translationX: (renderSize.width - clip.naturalSize.width * scale) / 2,
                y: (renderSize.height - clip.naturalSize.height * scale) / 2
            ).scaledBy(x: scale, y: scale)
            configuration.setTransform(transform, at: .zero)
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
            from: introEnd, to: routeEnd - fade,
            layers: [layerInstruction(track: trackB, clip: routeMap)])

        // Route map fades out to the black placeholder.
        addInstruction(
            from: routeEnd - fade, to: routeEnd,
            layers: [
                layerInstruction(
                    track: trackB, clip: routeMap,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: routeEnd - fade, end: routeEnd),
                        start: 1, end: 0))
            ])

        // Placeholder hold: no layers, so only the black background shows.
        addInstruction(from: routeEnd, to: outroStart, layers: [])

        // Outro fades in from black.
        addInstruction(
            from: outroStart, to: blackEnd,
            layers: [
                layerInstruction(
                    track: trackA, clip: outro,
                    opacityRamp: .init(
                        timeRange: CMTimeRange(start: outroStart, end: blackEnd),
                        start: 0, end: 1))
            ])

        // Outro alone.
        addInstruction(
            from: blackEnd, to: outroEnd,
            layers: [layerInstruction(track: trackA, clip: outro)])

        let videoComposition = AVVideoComposition(
            configuration: .init(
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
