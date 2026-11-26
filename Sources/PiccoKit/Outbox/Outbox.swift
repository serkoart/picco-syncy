import Foundation

public struct OutboxItem: Codable, Sendable, Identifiable, Equatable {
    /// `removed`: delivered earlier, but no longer on the Picco (deleted on the device).
    public enum State: String, Codable, Sendable { case queued, delivered, removed }

    public var id: UUID
    public var title: String
    public var author: String
    public var site: String
    public var source: String?
    public var createdAt: Date
    public var epubBytes: Int
    public var state: State
    public var deviceFileName: String?
    /// The path the Picco records in state.json, e.g. `/books/Articles/Title.epub`.
    public var devicePath: String?
    public var deliveredAt: Date?
    public var progress: ReadingProgress?

    public init(
        id: UUID = UUID(), title: String, author: String, site: String, source: String?,
        createdAt: Date = Date(), epubBytes: Int
    ) {
        self.id = id; self.title = title; self.author = author; self.site = site; self.source = source
        self.createdAt = createdAt; self.epubBytes = epubBytes; self.state = .queued
    }
}

/// Items waiting for, or already delivered to, the Picco. One folder per item:
/// `Outbox/<uuid>/item.json` and `Outbox/<uuid>/book.epub`.
public struct Outbox: Sendable {
    public let root: URL

    /// `$PICCO_HOME`, else `~/Library/Application Support/PiccoSync`.
    /// (Moves to the App Group container when the Share extension arrives in M3.)
    public static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["PICCO_HOME"], !custom.isEmpty {
            return URL(filePath: custom, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "PiccoSync", directoryHint: .isDirectory)
    }

    public init(root: URL = Outbox.defaultRoot) { self.root = root }

    var itemsFolder: URL { root.appending(path: "Outbox", directoryHint: .isDirectory) }

    func folder(for id: UUID) -> URL { itemsFolder.appending(path: id.uuidString, directoryHint: .isDirectory) }

    public func epubURL(for item: OutboxItem) -> URL { folder(for: item.id).appending(path: "book.epub") }

    public func add(epub: Data, item: OutboxItem) throws {
        let dir = folder(for: item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try epub.write(to: dir.appending(path: "book.epub"), options: .atomic)
        try save(item)
    }

    public func save(_ item: OutboxItem) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: folder(for: item.id).appending(path: "item.json"), options: .atomic)
    }

    /// All items, oldest first. Unreadable entries are skipped.
    public func items() -> [OutboxItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: itemsFolder.path)) ?? []
        return ids.compactMap { name -> OutboxItem? in
            guard let id = UUID(uuidString: name),
                let data = try? Data(contentsOf: folder(for: id).appending(path: "item.json"))
            else { return nil }
            return try? decoder.decode(OutboxItem.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ item: OutboxItem) throws {
        try FileManager.default.removeItem(at: folder(for: item.id))
    }
}
