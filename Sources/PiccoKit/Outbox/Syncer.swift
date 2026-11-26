import Foundation

public struct SyncReport: Sendable {
    public var delivered: [OutboxItem] = []
    public var progressUpdated: [OutboxItem] = []
    /// Delivered earlier but deleted from the Picco since.
    public var removedOnDevice: [OutboxItem] = []
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

        // Articles deleted on the Picco: mark them removed so the Mac stops listing them as "on Picco".
        let onDevice = Set(device.existingArticleNames().map(ProgressIndex.key))
        for var item in outbox.items() where item.state == .delivered {
            guard let name = item.deviceFileName, !onDevice.contains(ProgressIndex.key(name)) else { continue }
            item.state = .removed
            if (try? outbox.save(item)) != nil { report.removedOnDevice.append(item) }
        }

        let progress = ProgressIndex(device.readProgress())
        for var item in outbox.items() where item.state == .delivered {
            guard let path = item.devicePath, let p = progress.lookup(path), p != item.progress else { continue }
            item.progress = p
            if (try? outbox.save(item)) != nil { report.progressUpdated.append(item) }
        }

        device.tidy()
        return report
    }
}

/// Looks up reading progress by device path, tolerating differences the Picco or FAT32 may introduce:
/// Unicode normalisation (decomposed vs precomposed), letter case, and a different folder prefix.
struct ProgressIndex {
    private var byPath: [String: ReadingProgress] = [:]
    private var byName: [String: [ReadingProgress]] = [:]

    init(_ progress: [String: ReadingProgress]) {
        for (path, p) in progress {
            byPath[Self.key(path)] = p
            byName[Self.key((path as NSString).lastPathComponent), default: []].append(p)
        }
    }

    func lookup(_ path: String) -> ReadingProgress? {
        if let exact = byPath[Self.key(path)] { return exact }
        // Fall back to the file name, but only when it's unambiguous.
        if let matches = byName[Self.key((path as NSString).lastPathComponent)], matches.count == 1 {
            return matches[0]
        }
        return nil
    }

    static func key(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }
}
