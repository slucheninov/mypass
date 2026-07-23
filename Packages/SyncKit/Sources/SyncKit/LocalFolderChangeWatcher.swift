import Foundation
import CoreServices

public final class LocalFolderChangeWatcher {
    private let folderURL: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.mypass.sync.fsevents.debounce")
    private static let debounceInterval: TimeInterval = 0.5

    public init(folderURL: URL, onChange: @escaping () -> Void) {
        self.folderURL = folderURL
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }

        let pathsToWatch = [folderURL.path] as CFArray
        // Pass `self` as unretained context so the C callback can call back into this instance.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<LocalFolderChangeWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.handleRawEvent()
        }

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0, // latency handled by our own debounce, not FSEvents' built-in latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            return
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, debounceQueue)
        FSEventStreamStart(newStream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    /// Called on `debounceQueue` from the C trampoline. Coalesces rapid-fire
    /// events into a single `onChange` call at least `debounceInterval` apart.
    private func handleRawEvent() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        debounceQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    deinit {
        stop()
    }
}
