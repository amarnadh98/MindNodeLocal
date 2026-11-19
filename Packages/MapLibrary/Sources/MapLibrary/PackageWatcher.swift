import CoreServices
import Foundation

/// Delivers changed-path batches for watched folders. Real
/// implementations wrap FSEvents; tests inject fakes. One handler per
/// source (the library routes every batch through one debouncer).
public protocol PackageEventSource: Sendable {
    /// Installs the one batch handler; replaces any earlier one.
    func setHandler(_ handler: @escaping @Sendable ([URL]) -> Void)
    func addWatchedFolder(_ folder: URL)
    func removeWatchedFolder(_ folder: URL)
    func stopAll()
}

/// A test double: records the handler and folders, lets tests emit
/// synthetic batches and inspect registration.
public final class FakePackageEventSource: PackageEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable ([URL]) -> Void)?
    private var _folders: [URL] = []

    public init() {}

    public var handlerWasSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _handler != nil
    }

    public var folders: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _folders
    }

    public func setHandler(_ handler: @escaping @Sendable ([URL]) -> Void) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    public func addWatchedFolder(_ folder: URL) {
        lock.lock()
        _folders.append(folder)
        lock.unlock()
    }

    public func removeWatchedFolder(_ folder: URL) {
        lock.lock()
        _folders.removeAll { $0 == folder }
        lock.unlock()
    }

    public func stopAll() {
        lock.lock()
        _folders.removeAll()
        lock.unlock()
    }

    /// Emits a synthetic change batch, as FSEvents would.
    public func emit(_ urls: [URL]) {
        lock.lock()
        let handler = _handler
        lock.unlock()
        handler?(urls)
    }
}

/// Debounces watcher batches (F-LIB-3's "background watcher, updated on
/// save plus external changes"). Events arriving within the debounce
/// window coalesce into one batch — one reindex pass per burst of
/// saves, not one per FSEvents callback.
public actor LibraryWatcher {
    private let debounce: Duration
    private var source: (any PackageEventSource)?
    private var pending: Set<URL> = []
    private var flushTask: Task<Void, Never>?
    /// Increments on every event (and every explicit flush); a sleep
    /// that expires only fires when it is still the newest generation —
    /// a canceled or superseded timer never flushes early.
    private var generation = 0
    private var batchHandler: (@Sendable ([URL]) -> Void)?

    public init(debounce: Duration = .seconds(1)) {
        self.debounce = debounce
    }

    /// Registers the batch handler and, from then on, forwards folder
    /// changes on the attached event source into the debouncer.
    public func attach(to source: any PackageEventSource) {
        self.source = source
        source.setHandler { [weak self] urls in
            guard let self else { return }
            Task { await self.simulateEvents(urls) }
        }
    }

    /// Starts watching a folder on the attached source.
    public func watch(folder: URL) {
        source?.addWatchedFolder(folder)
    }

    /// Stops watching a folder on the attached source.
    public func unwatch(folder: URL) {
        source?.removeWatchedFolder(folder)
    }

    public func stopAll() {
        source?.stopAll()
    }

    /// Sets the coalesced-batch destination (reindex triggers).
    public func onBatch(_ handler: @escaping @Sendable ([URL]) -> Void) {
        batchHandler = handler
    }

    /// A change batch: merges into the pending set and (re)schedules
    /// the debounced flush. Tests call this directly with fakes; the
    /// FSEvents source calls it through `attach`.
    public func simulateEvents(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.formUnion(urls)
        flushTask?.cancel()
        generation += 1
        let current = generation
        let delay = debounce
        flushTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Superseded by a newer event: the newest timer owns
                // the flush; never fire early.
                return
            }
            self.flushIfCurrent(generation: current)
        }
    }

    /// Fires the pending batch immediately (also the debounce expiry
    /// path). Safe to call with nothing pending.
    public func flush() async {
        flushTask?.cancel()
        generation += 1
        flushIfCurrent(generation: generation)
    }

    private func flushIfCurrent(generation current: Int) {
        flushTask = nil
        guard current == generation, !pending.isEmpty else { return }
        let batch = Array(pending)
        pending.removeAll()
        batchHandler?(batch)
    }
}

/// The production source (F-LIB-3): one FSEvents stream per source over
/// all watched roots, file-level events, delivered on a private queue.
/// Sandboxed access works because the caller starts each folder's
/// security scope before watching (the watched-folder list owns that).
public final class FSEventsPackageEventSource: PackageEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "library.fsevents.arbor")
    private var handler: (@Sendable ([URL]) -> Void)?
    private var paths: [String] = []
    private var stream: FSEventStreamRef?
    private var boxPointer: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        teardownStream()
    }

    public func setHandler(_ handler: @escaping @Sendable ([URL]) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
        restartStream()
    }

    public func addWatchedFolder(_ folder: URL) {
        lock.lock()
        let path = folder.path
        guard !paths.contains(path) else {
            lock.unlock()
            return
        }
        paths.append(path)
        lock.unlock()
        restartStream()
    }

    public func removeWatchedFolder(_ folder: URL) {
        lock.lock()
        paths.removeAll { $0 == folder.path }
        lock.unlock()
        restartStream()
    }

    public func stopAll() {
        lock.lock()
        paths.removeAll()
        lock.unlock()
        restartStream()
    }

    /// Rebuilds the single stream over the current folder set. The
    /// stream's context box is retained for the stream's lifetime and
    /// released on teardown.
    private func restartStream() {
        lock.lock()
        defer { lock.unlock() }
        teardownStream()
        guard !paths.isEmpty, let handler else { return }

        final class CallbackBox: @unchecked Sendable {
            let handler: @Sendable ([URL]) -> Void

            init(handler: @escaping @Sendable ([URL]) -> Void) {
                self.handler = handler
            }
        }
        let box = CallbackBox(handler: handler)
        boxPointer = Unmanaged.passRetained(box).toOpaque()

        var context = FSEventStreamContext(
            version: 0, info: boxPointer, retain: nil, release: nil, copyDescription: nil)
        let flags: UInt32 =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) | UInt32(kFSEventStreamCreateFlagFileEvents)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, eventPaths, _, _ in
                    guard let info else { return }
                    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                        return
                    }
                    box.handler(paths.map { URL(fileURLWithPath: $0) })
                },
                &context,
                paths as NSArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                flags)
        else {
            Unmanaged<CallbackBox>.fromOpaque(boxPointer!).release()
            boxPointer = nil
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func teardownStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let boxPointer {
            Unmanaged<NSObject>.fromOpaque(boxPointer).release()
            self.boxPointer = nil
        }
    }
}
