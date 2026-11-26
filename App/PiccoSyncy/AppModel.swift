import AppKit
import Observation
import PiccoKit
import ServiceManagement
import UserNotifications

/// Everything the menu shows, plus the behaviour behind it: watching for the Picco, syncing, sending links.
@MainActor
@Observable
final class AppModel {
    // MARK: State shown in the menu

    private(set) var items: [OutboxItem] = []
    private(set) var device: PiccoDevice?
    private(set) var isSyncing = false
    private(set) var isSending = false
    private(set) var lastSync: Date?
    /// A short confirmation, e.g. "Delivered 2 articles".
    private(set) var message: String?
    private(set) var errorMessage: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var waiting: [OutboxItem] { items.filter { $0.state == .queued } }
    var onPicco: [OutboxItem] {
        items.filter { $0.state == .delivered }.sorted { ($0.deliveredAt ?? $0.createdAt) > ($1.deliveredAt ?? $1.createdAt) }
    }

    // MARK: Settings

    var autoSync: Bool { didSet { defaults.set(autoSync, forKey: Keys.autoSync) } }
    var autoEject: Bool { didSet { defaults.set(autoEject, forKey: Keys.autoEject) } }
    var includeImages: Bool { didSet { defaults.set(includeImages, forKey: Keys.includeImages) } }

    private enum Keys {
        static let autoSync = "autoSync"
        static let autoEject = "autoEject"
        static let includeImages = "includeImages"
        static let lastSync = "lastSync"
    }

    // MARK: Plumbing

    let outbox = Outbox()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var outboxWatcher: DispatchSourceFileSystemObject?

    init() {
        defaults.register(defaults: [Keys.autoSync: true, Keys.autoEject: true, Keys.includeImages: true])
        autoSync = defaults.bool(forKey: Keys.autoSync)
        autoEject = defaults.bool(forKey: Keys.autoEject)
        includeImages = defaults.bool(forKey: Keys.includeImages)
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date

        refresh()
        device = PiccoDevice.findMounted()
        observeVolumes()
        watchOutbox()
    }

    /// Re-reads the outbox from disk. Cheap; called whenever the menu opens.
    func refresh() {
        items = outbox.items()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Sending

    func send(link text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host() != nil
        else {
            show(error: "That doesn’t look like a web address. Paste a link starting with https://")
            return
        }
        isSending = true
        defer { isSending = false }
        clearMessages()
        do {
            let result = try await ArticleSender.send(url: url, includeImages: includeImages, outbox: outbox)
            refresh()
            show(message: "Added “\(result.article.title)”")
        } catch {
            show(error: error.localizedDescription)
        }
    }

    func remove(_ item: OutboxItem) {
        do {
            try outbox.remove(item)
            refresh()
        } catch {
            show(error: "Couldn’t remove “\(item.title)”: \(error.localizedDescription)")
        }
    }

    // MARK: - Syncing

    func syncNow() async {
        guard let device, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        clearMessages()

        let outbox = self.outbox
        let report = await Task.detached(priority: .userInitiated) { Syncer.sync(outbox: outbox, device: device) }.value
        lastSync = Date()
        defaults.set(lastSync, forKey: Keys.lastSync)
        refresh()

        var summary = Self.summary(of: report)
        // Only eject when we actually delivered something. If there was nothing new, the Picco was
        // probably mounted for another reason (Finder, booxtiles.com), so leave it alone.
        if autoEject, !report.delivered.isEmpty, report.failures.isEmpty {
            if await ejectDevice() { summary += " Safe to unplug." }
            else { summary += " Couldn’t eject — eject it in Finder before unplugging." }
        } else if self.device != nil {
            summary += " The Picco is still connected."
        }
        if report.failures.isEmpty {
            show(message: summary)
        } else {
            let failed = report.failures.map { "“\($0.title)”: \($0.reason)" }.joined(separator: "\n")
            show(error: summary + "\n" + failed)
        }
        if !report.delivered.isEmpty || !report.failures.isEmpty {
            await notify(title: "Picco synced", body: summary)
        }
    }

    /// Ejects the Picco from the panel's Eject button (or after a sync).
    func eject() async {
        clearMessages()
        if await ejectDevice() { show(message: "Ejected. Safe to unplug.") }
        else { show(error: "Couldn’t eject the Picco. Close any Finder windows showing it and try again.") }
    }

    private func ejectDevice() async -> Bool {
        guard let device else { return true }
        do {
            try await device.eject()
            self.device = nil
            return true
        } catch {
            return false
        }
    }

    static func summary(of report: SyncReport) -> String {
        let n = report.delivered.count
        var text = n == 0 ? "Nothing new to deliver." : "Delivered \(n) article\(n == 1 ? "" : "s")."
        let finished = report.progressUpdated.filter { $0.progress?.finished == true }.count
        if finished > 0 { text += " \(finished) finished." }
        return text
    }

    // MARK: - Volume watching

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) {
            [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
            [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeUnmounted(url) }
        })
    }

    private func volumeMounted(_ url: URL?) {
        guard let url, url.lastPathComponent == PiccoDevice.volumeName, let picco = try? PiccoDevice(root: url) else {
            return
        }
        device = picco
        refresh()
        guard autoSync else {
            Task { await notify(title: "Picco connected", body: "Open Picco Syncy to sync.") }
            return
        }
        Task {
            // Give Finder and Spotlight a moment to finish looking at the new volume.
            try? await Task.sleep(for: .seconds(1.5))
            await syncNow()
        }
    }

    private func volumeUnmounted(_ url: URL?) {
        guard let url, let device, url.standardizedFileURL.path == device.root.standardizedFileURL.path else { return }
        self.device = nil
    }

    /// Notices items added by the CLI (or, later, the Share extension) while the app is running.
    private func watchOutbox() {
        let folder = outbox.root.appending(path: "Outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // item.json lands a moment after its folder appears.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refresh()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        outboxWatcher = source
    }

    // MARK: - Settings actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(error: "Couldn’t change Open at Login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openOutboxFolder() {
        let folder = outbox.root.appending(path: "Outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Messages and notifications

    private func show(message: String) {
        errorMessage = nil
        self.message = message
    }

    private func show(error: String) {
        message = nil
        errorMessage = error
    }

    func clearMessages() {
        message = nil
        errorMessage = nil
    }

    private func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
