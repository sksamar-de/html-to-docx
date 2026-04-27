import Foundation
import CoreServices

/// Wraps an `FSEventStream` watching a single directory.
/// Emits a callback (on the main queue) for any `.html`/`.htm` file that
/// is created or modified. We deduplicate by inode/path+mtime so a single
/// editor save (which can fire many events) becomes one conversion.
final class FolderWatcher {

    typealias Handler = (URL) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "FolderWatcher", qos: .utility)
    private var observedURL: URL?
    private var lastSeen: [String: Date] = [:]
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { stream != nil }

    func start(at url: URL) -> Bool {
        stop()
        let path = url.path
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return false }

        observedURL = url

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))
        defer {
            context.deinitialize(count: 1)
            context.deallocate()
        }

        let pathsToWatch = [path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info = info else { return }
                let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                let flagsPtr = eventFlags
                me.handleEvents(paths: paths, flags: flagsPtr, count: numEvents)
            },
            context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // coalesce window in seconds
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(s, queue)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }

        stream = s
        return true
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        observedURL = nil
        lastSeen.removeAll()
    }

    // MARK: - Event handling

    private func handleEvents(paths: [String],
                              flags: UnsafePointer<FSEventStreamEventFlags>,
                              count: Int) {
        for i in 0..<count {
            let path = paths[i]
            let f = flags[i]

            // Only react to creation, rename-into-folder, or modification.
            let interesting =
                (f & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 ||
                (f & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 ||
                (f & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                (f & UInt32(kFSEventStreamEventFlagItemFinderInfoMod)) != 0
            guard interesting else { continue }

            let lower = (path as NSString).pathExtension.lowercased()
            guard lower == "html" || lower == "htm" else { continue }

            // File must currently exist (renames can deliver vanished paths).
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }

            // Debounce by (path → mtime).
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            let key = path
            if let last = lastSeen[key], let m = mtime, m.timeIntervalSince(last) < 0.5 {
                continue
            }
            if let m = mtime { lastSeen[key] = m }

            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { [weak self] in
                self?.handler(url)
            }
        }
    }
}
