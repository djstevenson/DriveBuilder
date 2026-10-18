import Foundation

/// Times typed and shown as on a video player's clock: "25:03",
/// "1:02:03.5", or plain seconds ("1503.5").
package enum ClockTime {
    /// Seconds from `text`: `[[h:]m:]s` with optional fractional seconds,
    /// or plain seconds. Nil if it doesn't parse or is negative.
    package static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(
            separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
            let secondsPart = parts.last.flatMap({ Double($0) }), secondsPart >= 0
        else { return nil }
        // Whole minutes and hours only, and with a clock, seconds under 60.
        var total = secondsPart
        if parts.count > 1 {
            guard secondsPart < 60 else { return nil }
            var multiplier = 60.0
            for part in parts.dropLast().reversed() {
                guard let value = Int(part), value >= 0 else { return nil }
                total += Double(value) * multiplier
                multiplier *= 60
            }
            // Minutes under 60 when hours are given.
            if parts.count == 3, let minutes = Int(parts[1]), minutes >= 60 { return nil }
        }
        return total
    }

    /// `seconds` as "m:ss" (or "h:mm:ss"), with tenths when not whole.
    package static func text(for seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10 == 0 ? "" : ".\(tenths % 10)"
        let (hours, minutes, secs) = (whole / 3600, (whole % 3600) / 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) + fraction
            : String(format: "%d:%02d", minutes, secs) + fraction
    }
}
