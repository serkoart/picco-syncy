import Foundation

/// A page shared from the "Send to Picco" extension, waiting for the app to convert it.
struct ShareJob: Codable, Sendable {
    var id: UUID
    /// The page address.
    var url: String
    var title: String?
    var includeImages: Bool
    /// True when `Inbox/<id>.html` holds the page as Safari rendered it.
    var hasHTML: Bool
    var createdAt: Date
}

/// The hand-off folder between the sandboxed Share extension and the app, inside their shared App Group
/// container. The extension only writes jobs; the app (which has network access and WebKit) converts them.
///
/// Compiled into both targets. The App Group ID comes from each bundle's Info.plist (`PiccoAppGroup`),
/// which is built from the signing team, so contributors' builds use their own group.
enum ShareInbox {
    static let openURL = URL(string: "piccosyncy://inbox")!

    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "PiccoAppGroup") as? String
    }

    static var folder: URL? {
        guard let groupID,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        let inbox = container.appending(path: "Inbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Settings both sides can read (the default for "Include images").
    static var defaults: UserDefaults? { groupID.flatMap(UserDefaults.init(suiteName:)) }
    static let includeImagesKey = "includeImages"

    /// Writes the page first and the job last: a job file's presence means the job is complete.
    static func write(_ job: ShareJob, html: String?) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        if let html {
            try Data(html.utf8).write(to: folder.appending(path: "\(job.id.uuidString).html"), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: folder.appending(path: "\(job.id.uuidString).json"), options: .atomic)
    }

    /// Waiting jobs, oldest first, with their saved page if any.
    static func pending() -> [(job: ShareJob, html: String?)] {
        guard let folder else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> (ShareJob, String?)? in
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                let job = try? decoder.decode(ShareJob.self, from: data)
            else { return nil }
            let html = job.hasHTML
                ? try? String(contentsOf: folder.appending(path: "\(job.id.uuidString).html"), encoding: .utf8)
                : nil
            return (job, html)
        }
        .sorted { $0.0.createdAt < $1.0.createdAt }
    }

    static func remove(_ job: ShareJob) {
        guard let folder else { return }
        for ext in ["json", "html"] {
            try? FileManager.default.removeItem(at: folder.appending(path: "\(job.id.uuidString).\(ext)"))
        }
    }
}
