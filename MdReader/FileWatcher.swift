import Foundation

/// Watches a single file for changes and calls `onChange` (debounced) when it is
/// written, or replaced by an atomic save. Editors commonly save atomically
/// (write a temp file, then rename it over the original), which swaps the inode,
/// so on rename/delete the watch re-establishes itself on the path.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.qbyteconsulting.MdReader.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stopped = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.start() }
    }

    deinit { stop() }

    private func start() {
        guard !stopped else { return }
        source?.cancel()
        source = nil

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet (e.g. mid atomic-save). Retry shortly.
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib, .revoke],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            self.scheduleChange()
            // The watched inode was replaced/removed — rewatch the path.
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        // Coalesce bursts of events from a single save.
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func stop() {
        stopped = true
        debounce?.cancel()
        source?.cancel()
        source = nil
    }
}
