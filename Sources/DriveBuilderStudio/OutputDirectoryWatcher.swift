import Foundation

/// Watches journeys' output directories for files appearing, disappearing,
/// or being renamed (a movie deleted or trashed in Finder, say) and reports
/// it, coalesced, so the windows can re-stat their outputs.
///
/// A directory's vnode reports `.write` when its entries change, not when
/// a file inside is written to, so a render in progress only triggers it
/// when it creates or renames its output.
final class OutputDirectoryWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingChange: Task<Void, Never>?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Watches exactly these directories, of those that exist: starts on
    /// new ones and stops on any no longer listed or since removed. A
    /// directory that doesn't exist yet (nothing rendered) is picked up on
    /// a later call.
    func watch(_ paths: Set<String>) {
        for (path, source) in sources
        where !paths.contains(path) || !FileManager.default.fileExists(atPath: path) {
            source.cancel()
            sources[path] = nil
        }
        for path in paths where sources[path] == nil {
            // O_EVTONLY so the watch never stops the external video drive
            // from being ejected.
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                self?.changed()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources[path] = source
        }
    }

    /// Waits for a burst of changes (a Finder delete can be several) to
    /// settle before reporting once.
    private func changed() {
        pendingChange?.cancel()
        pendingChange = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
