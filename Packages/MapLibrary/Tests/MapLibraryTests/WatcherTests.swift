import Foundation
import Testing

@testable import MapLibrary

@Suite struct WatcherTests {
    @Test func debounceCoalescesBurstsIntoOneBatch() async throws {
        let watcher = LibraryWatcher(debounce: .milliseconds(200))
        let received = BatchRecorder()
        await watcher.onBatch(received.record)

        await watcher.simulateEvents([URL(fileURLWithPath: "/tmp/a.arbor")])
        await watcher.simulateEvents([URL(fileURLWithPath: "/tmp/b.arbor")])
        await watcher.simulateEvents([URL(fileURLWithPath: "/tmp/a.arbor/map.json")])

        // Before the window closes: nothing fired, all merged.
        try await Task.sleep(for: .milliseconds(50))
        #expect(received.batches.isEmpty)

        // After the window: exactly one batch, all three paths.
        try await Task.sleep(for: .milliseconds(400))
        #expect(received.batches.count == 1)
        #expect(
            Set(received.batches[0])
                == Set([
                    URL(fileURLWithPath: "/tmp/a.arbor"),
                    URL(fileURLWithPath: "/tmp/b.arbor"),
                    URL(fileURLWithPath: "/tmp/a.arbor/map.json"),
                ]))
    }

    @Test func flushFiresImmediatelyAndClearsPending() async throws {
        let watcher = LibraryWatcher(debounce: .seconds(60))
        let received = BatchRecorder()
        await watcher.onBatch(received.record)

        await watcher.simulateEvents([URL(fileURLWithPath: "/tmp/one.arbor")])
        await watcher.simulateEvents([URL(fileURLWithPath: "/tmp/two.arbor")])
        await watcher.flush()

        #expect(received.batches.count == 1)
        #expect(Set(received.batches[0]).count == 2)

        // Flushing with nothing pending fires nothing.
        await watcher.flush()
        #expect(received.batches.count == 1)
    }

    @Test func attachForwardsSourceEventsThroughTheDebouncer() async throws {
        let source = FakePackageEventSource()
        let watcher = LibraryWatcher(debounce: .milliseconds(20))
        let received = BatchRecorder()
        await watcher.onBatch(received.record)
        await watcher.attach(to: source)
        #expect(source.handlerWasSet)

        await watcher.watch(folder: URL(fileURLWithPath: "/tmp/maps"))
        #expect(source.folders == [URL(fileURLWithPath: "/tmp/maps")])

        source.emit([URL(fileURLWithPath: "/tmp/maps/changed.arbor")])
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.batches.count == 1)
        #expect(received.batches[0] == [URL(fileURLWithPath: "/tmp/maps/changed.arbor")])
    }

    @Test func fseventsSourceRegistersFoldersAndTearsDown() {
        // The real source can't be driven headlessly (needs a live
        // stream); cover registration, handler swaps and stop paths.
        let source = FSEventsPackageEventSource()
        let folderA = URL(fileURLWithPath: "/tmp/folder-a")
        source.setHandler { _ in }
        source.addWatchedFolder(folderA)
        source.addWatchedFolder(folderA)  // deduplicated
        source.removeWatchedFolder(folderA)
        source.addWatchedFolder(folderA)
        source.setHandler { _ in }  // stream restart with a new handler
        source.stopAll()
    }

    @Test func packageURLsMapEventsInsidePackagesToThePackage() {
        let package = URL(fileURLWithPath: "/tmp/Maps/Book.arbor")
        let inner = package.appendingPathComponent("map.json")
        let nested = package.appendingPathComponent("QuickLook/Thumbnail.png")
        let trailingSlash = URL(fileURLWithPath: "/tmp/Maps/Book.arbor/", isDirectory: true)
        let result = LibraryService.packageURLs(
            from: [package, inner, nested, trailingSlash, URL(fileURLWithPath: "/tmp/other.txt")])
        #expect(result.map(\.path) == ["/tmp/Maps/Book.arbor"])
    }
}

/// Records batches on whatever thread they arrive on.
private final class BatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[URL]] = []

    var batches: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return _batches
    }

    func record(_ urls: [URL]) {
        lock.lock()
        _batches.append(urls)
        lock.unlock()
    }
}
