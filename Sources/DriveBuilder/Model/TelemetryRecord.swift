import Foundation

/// A single row of the `telemetry` table: one sampled instant of a journey.
struct TelemetryRecord: Sendable, Identifiable {
    let id: Int64
    let journeyID: Int64
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let heading: Double
    let accelForward: Double?
    let accelLateral: Double?
    let speedLimit: Int?
    let file: String?
    let source: String
}
