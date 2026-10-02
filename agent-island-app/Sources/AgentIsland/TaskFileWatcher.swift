import Foundation

final class TaskFileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "agent-island.task-file-watcher", qos: .utility)
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var descriptor: Int32 = -1
    private var stopped = false
    private var lastSignature = ""
    private var lastCallbackAt = Date.distantPast

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.lastSignature = self.signature()
            self.installFileSource()
            self.installPollTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.fileSource?.cancel()
            self.fileSource = nil
            self.pollTimer?.cancel()
            self.pollTimer = nil
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
        }
    }

    private func installFileSource() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
    }

    private func installPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.signature() != self.lastSignature else { return }
            self.scheduleChange()
        }
        pollTimer = timer
        timer.resume()
    }

    private func scheduleChange() {
        guard !stopped else { return }
        let current = signature()
        guard current != lastSignature else { return }
        lastSignature = current
        let now = Date()
        guard now.timeIntervalSince(lastCallbackAt) >= 0.25 else { return }
        lastCallbackAt = now
        DispatchQueue.main.async(execute: onChange)
    }

    private func signature() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(modified)"
    }
}
