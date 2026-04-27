import Foundation
import AppKit
import Combine

/// Single source of truth for the running app: the two folder bookmarks,
/// the watcher state, the on-screen status messages and the launch-at-login
/// flag. Persisted via `UserDefaults` so the next launch picks up where it
/// left off.
///
/// All `@Published` mutations happen on the main queue (either because the
/// caller is already on main, or via an explicit `DispatchQueue.main.async`).
final class AppViewModel: ObservableObject {

    @Published var observerPath: String = "" {
        didSet { defaults.set(observerPath, forKey: Keys.observer); restartIfRunning() }
    }
    @Published var targetPath: String = "" {
        didSet { defaults.set(targetPath, forKey: Keys.target); restartIfRunning() }
    }

    @Published private(set) var isWatching: Bool = false
    @Published private(set) var lastEvent: String = "Idle."
    @Published private(set) var converted: Int = 0
    @Published private(set) var failed: Int = 0
    @Published var launchAtLogin: Bool {
        didSet {
            if launchAtLogin != oldValue {
                _ = LaunchAtLogin.setEnabled(launchAtLogin)
            }
        }
    }

    private enum Keys {
        static let observer = "ObserverPath"
        static let target = "TargetPath"
        static let autoStart = "AutoStart"
    }

    private let defaults = UserDefaults.standard
    private let watcher: FolderWatcher
    private let conversionQueue = DispatchQueue(
        label: "HTMLtoDOCX.conversion",
        qos: .userInitiated
    )

    init() {
        self.observerPath = defaults.string(forKey: Keys.observer) ?? ""
        self.targetPath   = defaults.string(forKey: Keys.target)   ?? ""
        self.launchAtLogin = LaunchAtLogin.isEnabled
        var capturedHandler: ((URL) -> Void)?
        self.watcher = FolderWatcher { url in capturedHandler?(url) }
        capturedHandler = { [weak self] url in self?.fileChanged(url: url) }

        // Auto-start if both paths are configured.
        if !observerPath.isEmpty, !targetPath.isEmpty {
            startWatching()
        }
    }

    // MARK: - Public actions

    func chooseObserver() {
        if let url = pickFolder(prompt: "Choose Observer Folder") {
            observerPath = url.path
        }
    }

    func chooseTarget() {
        if let url = pickFolder(prompt: "Choose Target Folder") {
            targetPath = url.path
        }
    }

    func toggleWatching() {
        isWatching ? stopWatching() : startWatching()
    }

    func reconvertAll() {
        guard !observerPath.isEmpty, !targetPath.isEmpty else { return }
        let observer = URL(fileURLWithPath: observerPath)
        conversionQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: observer.path) else { return }
            for item in items where item.lowercased().hasSuffix(".html") || item.lowercased().hasSuffix(".htm") {
                let url = observer.appendingPathComponent(item)
                self.performConversion(url: url, announce: false)
            }
            DispatchQueue.main.async {
                self.lastEvent = "Reconverted \(items.count) files."
            }
        }
    }

    // MARK: - Watching

    func startWatching() {
        guard !observerPath.isEmpty, !targetPath.isEmpty else {
            lastEvent = "Set both Observer and Target folders first."
            return
        }
        let observer = URL(fileURLWithPath: observerPath)
        let started = watcher.start(at: observer)
        isWatching = started
        lastEvent = started
            ? "Watching \(observer.path)"
            : "Could not watch \(observer.path) — does it exist?"
    }

    func stopWatching() {
        watcher.stop()
        isWatching = false
        lastEvent = "Stopped."
    }

    private func restartIfRunning() {
        if isWatching {
            stopWatching()
            startWatching()
        }
    }

    // MARK: - Conversion plumbing

    private func fileChanged(url: URL) {
        // Wait briefly so the writer process can flush; some editors create
        // the file empty and then write its bytes a moment later.
        conversionQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.performConversion(url: url, announce: true)
        }
    }

    private func performConversion(url: URL, announce: Bool) {
        let target = URL(fileURLWithPath: targetPath)
        do {
            let result = try HTMLToDocxConverter.convert(htmlURL: url, targetDirectory: target)
            DispatchQueue.main.async {
                self.converted += 1
                if announce {
                    self.lastEvent = String(
                        format: "Converted %@ → %@ (%d blocks, %.0f ms)",
                        result.source.lastPathComponent,
                        result.destination.lastPathComponent,
                        result.blocks, result.durationMS
                    )
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.failed += 1
                self.lastEvent = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helpers

    private func pickFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
