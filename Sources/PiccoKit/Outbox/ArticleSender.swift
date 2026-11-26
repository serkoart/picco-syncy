import Foundation

/// The one way articles get into the outbox: extract → assemble → EPUB → queue.
/// Shared by the CLI, the menu-bar app, and (in M3) the Share extension's host app.
@MainActor
public enum ArticleSender {
    public enum SendError: LocalizedError {
        case alreadyInOutbox(OutboxItem)

        public var errorDescription: String? {
            switch self {
            case .alreadyInOutbox(let item):
                item.state == .queued
                    ? "“\(item.title)” is already waiting to go to the Picco."
                    : "“\(item.title)” is already on the Picco."
            }
        }
    }

    public struct Result: Sendable {
        public var item: OutboxItem
        public var article: ArticleAssembler.Article
    }

    /// Fetches and converts a web page, then queues it.
    public static func send(
        url: URL, includeImages: Bool, outbox: Outbox = Outbox(), allowDuplicate: Bool = false
    ) async throws -> Result {
        try checkDuplicate(url.absoluteString, in: outbox, allowDuplicate: allowDuplicate)
        let page = try await WebExtractor().extract(url: url, includeImages: includeImages)
        return try await queue(page, outbox: outbox)
    }

    /// Converts HTML captured elsewhere (e.g. from Safari), then queues it.
    public static func send(
        html: String, baseURL: URL, includeImages: Bool, outbox: Outbox = Outbox(), allowDuplicate: Bool = false
    ) async throws -> Result {
        try checkDuplicate(baseURL.absoluteString, in: outbox, allowDuplicate: allowDuplicate)
        let page = try await WebExtractor().extract(html: html, baseURL: baseURL, includeImages: includeImages)
        return try await queue(page, outbox: outbox)
    }

    /// Converts without queueing (for previews and `picco epub`).
    public static func convert(url: URL, includeImages: Bool) async throws -> ArticleAssembler.Article {
        let page = try await WebExtractor().extract(url: url, includeImages: includeImages)
        return try await ArticleAssembler.assemble(page)
    }

    static func checkDuplicate(_ source: String, in outbox: Outbox, allowDuplicate: Bool) throws {
        // Articles deleted from the Picco can be sent again.
        guard !allowDuplicate,
            let existing = outbox.items().first(where: { $0.source == source && $0.state != .removed })
        else { return }
        throw SendError.alreadyInOutbox(existing)
    }

    static func queue(_ page: ExtractedPage, outbox: Outbox) async throws -> Result {
        let article = try await ArticleAssembler.assemble(page)
        let epub = EPUBBuilder.build(article.document)
        let item = OutboxItem(
            id: article.document.identifier, title: article.title, author: article.author, site: article.site,
            source: article.source?.absoluteString, epubBytes: epub.count)
        try outbox.add(epub: epub, item: item)
        return Result(item: item, article: article)
    }
}
