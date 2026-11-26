import Foundation

public struct SyncReport: Sendable {
    public var delivered: [OutboxItem] = []
    public var progressUpdated: [OutboxItem] = []
    public var failures: [(title: String, reason: String)] = []
}

/// One sync pass: deliver queued items, then read progress back for everything delivered.
public enum Syncer {
    public static func sync(outbox: Outbox, device: PiccoDevice) -> SyncReport {
        var report = SyncReport()
        var existing = device.existingArticleNames()

        for var item in outbox.items() where item.state == .queued {
            do {
                let epub = try Data(contentsOf: outbox.epubURL(for: item))
                let name = FileNamer.unique(FileNamer.fileName(title: item.title, site: item.site), existing: existing)
                let path = try device.deliver(epub: epub, fileName: name)
                existing.insert(name)
                item.state = .delivered
                item.deviceFileName = name
                item.devicePath = path
                item.deliveredAt = Date()
                try outbox.save(item)
                report.delivered.append(item)
            } catch {
                report.failures.append((item.title, error.localizedDescription))
            }
        }

        let progress = device.readProgress()
        for var item in outbox.items() where item.state == .delivered {
            guard let path = item.devicePath, let p = progress[path], p != item.progress else { continue }
            item.progress = p
            if (try? outbox.save(item)) != nil { report.progressUpdated.append(item) }
        }

        device.tidy()
        return report
    }
}
