import Foundation

extension FileManager {
    /// Marks `url` excluded from Time Machine backups. Time Machine treats
    /// this as covering the whole subtree, including anything added later,
    /// so this only needs calling once per directory - but it's cheap and
    /// idempotent, so call sites just do it every time rather than tracking
    /// whether they already have.
    ///
    /// Used for the `output` directories this tool fills with video files:
    /// they're each gigabytes, but cheap to regenerate from the original
    /// footage, so there's no need to back them up.
    func excludeFromBackup(_ url: URL) throws {
        var url = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try url.setResourceValues(resourceValues)
    }
}
