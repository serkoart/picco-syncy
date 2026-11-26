import CoreGraphics
import Foundation

/// Turns an extracted page into an EPUB document: adds the title block, builds the table of contents
/// from headings, and downloads and converts images.
public enum ArticleAssembler {
    public struct Article: Sendable {
        public var document: EPUBDocument
        public var title: String
        public var author: String
        public var site: String
        public var source: URL?
        public var imagesKept: Int
        public var imagesDropped: Int
    }

    public enum AssemblyError: LocalizedError {
        case badMarkup(String)
        public var errorDescription: String? {
            switch self { case .badMarkup(let why): "The extracted article wasn't valid XHTML: \(why)" }
        }
    }

    public static func assemble(_ page: ExtractedPage, session: URLSession = .shared) async throws -> Article {
        let source = URL(string: page.url)
        let title = page.title.isEmpty ? (source?.host() ?? "Untitled") : page.title
        let site = !page.site.isEmpty ? page.site : page.domain.replacingOccurrences(of: "www.", with: "")
        let author = !page.author.isEmpty ? page.author : (site.isEmpty ? "Unknown" : site)

        let xmlDoc: XMLDocument
        do {
            xmlDoc = try XMLDocument(xmlString: page.html, options: [])
        } catch {
            throw AssemblyError.badMarkup(error.localizedDescription)
        }
        guard let root = xmlDoc.rootElement() else { throw AssemblyError.badMarkup("empty") }

        removeDuplicateTitle(in: root, title: title)
        demoteH1(in: root)
        let sections = addSectionIDs(in: root)

        // Images: download in parallel, convert, then rewrite or drop each <img>.
        let imgs = elements(named: "img", in: root)
        let urls = imgs.compactMap { $0.attribute(forName: "data-picco-src")?.stringValue }.compactMap(URL.init(string:))
        let converted = await downloadAndConvert(urls, referer: source, session: session)
        var images: [EPUBDocument.Image] = []
        var dropped = 0
        for img in imgs {
            guard let raw = img.attribute(forName: "data-picco-src")?.stringValue,
                let url = URL(string: raw), let jpeg = converted[url]
            else {
                img.detach()
                dropped += 1
                continue
            }
            let href = "images/img\(images.count + 1).jpg"
            images.append(.init(href: href, data: jpeg))
            img.removeAttribute(forName: "data-picco-src")
            img.addAttribute(XMLNode.attribute(withName: "src", stringValue: href) as! XMLNode)
            if img.attribute(forName: "alt") == nil {
                img.addAttribute(XMLNode.attribute(withName: "alt", stringValue: "") as! XMLNode)
            }
        }
        removeEmptyFigures(in: root)

        var metaParts: [String] = []
        if !page.author.isEmpty { metaParts.append(page.author) }
        if !site.isEmpty, site != page.author { metaParts.append(site) }
        if let shown = displayDate(page.published) { metaParts.append(shown) }

        var head = "<div class=\"picco-head\">\n<h1>\(xml(title))</h1>\n"
        if !metaParts.isEmpty { head += "<p class=\"picco-meta\">\(xml(metaParts.joined(separator: " · ")))</p>\n" }
        head += "</div>\n"
        var footer = ""
        if let source {
            footer = "<p class=\"picco-source\">Source: <a href=\"\(xml(source.absoluteString))\">\(xml(source.host() ?? source.absoluteString))</a></p>"
        }

        // Long articles become one chapter per section, so the Picco can show the first page without
        // first processing the whole article (it caches books chapter by chapter). The text is unchanged.
        let parts = splitIntoChapters(root)
        let multiple = parts.count > 1
        if multiple { relinkAcrossChapters(parts) }
        var chapters: [EPUBDocument.Chapter] = []
        for (i, part) in parts.enumerated() {
            var body = (i == 0 ? head : "") + serialize(part) + "\n"
            if i == parts.count - 1 { body += footer }
            let chapterTitle = i == 0 ? title : (firstHeadingText(in: part) ?? "Part \(i + 1)")
            chapters.append(.init(title: chapterTitle, bodyXHTML: body, sections: multiple ? [] : sections))
        }

        let cover = await makeCover(
            title: title, site: site.isEmpty ? author : site, pageImage: page.image.flatMap(URL.init(string:)),
            firstArticleImage: images.first?.data, referer: source, session: session)

        let language = page.language.isEmpty ? "en" : String(page.language.prefix(35))
        let document = EPUBDocument(
            title: title, author: author, publisher: site.isEmpty ? nil : site, language: language,
            source: source, date: isoDate(page.published),
            chapters: chapters,
            images: images, cover: cover.map { .init(href: "cover.jpg", data: $0) })
        return Article(
            document: document, title: title, author: author, site: site, source: source,
            imagesKept: images.count, imagesDropped: dropped)
    }

    // MARK: - Markup clean-up

    static func elements(named name: String, in root: XMLElement) -> [XMLElement] {
        var found: [XMLElement] = []
        func walk(_ el: XMLElement) {
            if el.localName == name { found.append(el) }
            for child in el.children ?? [] { if let c = child as? XMLElement { walk(c) } }
        }
        walk(root)
        return found
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Defuddle sometimes leaves the headline in the body. We print our own, so drop a leading duplicate.
    static func removeDuplicateTitle(in root: XMLElement, title: String) {
        let target = normalized(title)
        var node: XMLElement? = root
        // Descend through wrapper divs to the first real element.
        while let current = node, let first = current.children?.compactMap({ $0 as? XMLElement }).first {
            if ["h1", "h2"].contains(first.localName ?? ""), normalized(first.stringValue ?? "") == target {
                first.detach()
                return
            }
            if first.localName == "div" { node = first } else { return }
        }
    }

    static func demoteH1(in root: XMLElement) {
        for h in elements(named: "h1", in: root) { h.name = "h2" }
    }

    static func addSectionIDs(in root: XMLElement) -> [EPUBDocument.Section] {
        var sections: [EPUBDocument.Section] = []
        for (i, h) in elements(named: "h2", in: root).enumerated() {
            let text = (h.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id: String
            if let existing = h.attribute(forName: "id")?.stringValue, !existing.isEmpty {
                id = existing
            } else {
                id = "picco-s\(i + 1)"
                h.addAttribute(XMLNode.attribute(withName: "id", stringValue: id) as! XMLNode)
            }
            sections.append(.init(id: id, title: String(text.prefix(120))))
        }
        return sections
    }

    static func removeEmptyFigures(in root: XMLElement) {
        for fig in elements(named: "figure", in: root) where elements(named: "img", in: fig).isEmpty {
            // Keep a caption as an ordinary paragraph, drop the empty figure.
            if let caption = elements(named: "figcaption", in: fig).first,
                let text = caption.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                let parent = fig.parent as? XMLElement
            {
                let p = XMLElement(name: "p", stringValue: text)
                parent.insertChild(p, at: fig.index)
            }
            fig.detach()
        }
    }

    // MARK: - Chapters

    /// Split only articles bigger than this (bytes of XHTML), and only at two or more section headings.
    static let splitThreshold = 50_000

    static func serialize(_ part: XMLElement) -> String {
        part.removeAttribute(forName: "xmlns")
        part.removeAttribute(forName: "class")
        part.addAttribute(XMLNode.attribute(withName: "class", stringValue: "picco-article") as! XMLNode)
        return part.xmlString(options: [.nodeCompactEmptyElement])
            .replacingOccurrences(of: " xmlns=\"http://www.w3.org/1999/xhtml\"", with: "")
    }

    /// Splits the article at each `<h2>`, wherever it sits in the tree. Wrapper elements around a heading
    /// are copied, so each chapter keeps the same structure. Returns the parts in reading order; the first
    /// is whatever comes before the first heading (dropped if empty).
    static func splitIntoChapters(_ root: XMLElement) -> [XMLElement] {
        let headings = elements(named: "h2", in: root)
        guard headings.count >= 2,
            root.xmlString(options: [.nodeCompactEmptyElement]).utf8.count > splitThreshold
        else { return [root] }

        var tails: [XMLElement] = []
        for heading in headings.reversed() {
            tails.append(splitOff(from: heading))
        }
        var parts = [root] + tails.reversed()
        if !hasContent(parts[0]) { parts.removeFirst() }
        return parts
    }

    /// Moves `node` and everything after it (in document order) out of the article into a new tree.
    static func splitOff(from node: XMLElement) -> XMLElement {
        var level = node.parent as? XMLElement  // read before detaching, which clears it
        var carried: [XMLNode] = detachFollowing(including: node)
        while let ancestor = level {
            let shell = XMLElement(name: ancestor.name ?? "div")
            for attr in ancestor.attributes ?? [] where attr.name != "id" && attr.name != "xmlns" {
                shell.addAttribute(attr.copy() as! XMLNode)
            }
            for child in carried { shell.addChild(child) }
            // The article root is the top element: its parent is the document, not an element.
            guard let next = ancestor.parent as? XMLElement else { return shell }
            carried = [shell] + detachFollowing(including: nil, after: ancestor)
            level = next
        }
        return XMLElement(name: "div")
    }

    /// Detaches `node` (if given) and all siblings after it — or, with `after`, the siblings after that node.
    static func detachFollowing(including node: XMLNode?, after anchor: XMLNode? = nil) -> [XMLNode] {
        guard let start = node ?? anchor, let parent = start.parent, let siblings = parent.children else { return [] }
        let from = start.index + (node == nil ? 1 : 0)
        guard from < siblings.count else { return [] }
        let moving = Array(siblings[from...])
        for n in moving { n.detach() }
        return moving
    }

    static func hasContent(_ el: XMLElement) -> Bool {
        let text = (el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty || !elements(named: "img", in: el).isEmpty
    }

    static func firstHeadingText(in el: XMLElement) -> String? {
        guard let h = elements(named: "h2", in: el).first,
            let text = h.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return String(text.prefix(120))
    }

    /// Rewrites `href="#id"` links whose target landed in another chapter to `cN.xhtml#id`.
    static func relinkAcrossChapters(_ parts: [XMLElement]) {
        var home: [String: Int] = [:]
        for (i, part) in parts.enumerated() {
            func collect(_ el: XMLElement) {
                if let id = el.attribute(forName: "id")?.stringValue { home[id] = i }
                for c in el.children ?? [] { if let e = c as? XMLElement { collect(e) } }
            }
            collect(part)
        }
        for (i, part) in parts.enumerated() {
            for a in elements(named: "a", in: part) {
                guard let href = a.attribute(forName: "href")?.stringValue, href.hasPrefix("#") else { continue }
                let id = String(href.dropFirst())
                guard let target = home[id], target != i else { continue }
                a.removeAttribute(forName: "href")
                a.addAttribute(XMLNode.attribute(
                    withName: "href", stringValue: EPUBBuilder.chapterFile(target) + "#" + id) as! XMLNode)
            }
        }
    }

    // MARK: - Dates

    static func isoDate(_ raw: String) -> String? {
        let prefix = String(raw.prefix(10))
        return prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? prefix : nil
    }

    static func displayDate(_ raw: String) -> String? {
        guard let iso = isoDate(raw) else { return raw.isEmpty ? nil : String(raw.prefix(40)) }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Cover

    /// The page's main image if it downloads and is big enough, else the article's first image,
    /// else a typographic cover with no photo.
    static func makeCover(
        title: String, site: String, pageImage: URL?, firstArticleImage: Data?, referer: URL?, session: URLSession
    ) async -> Data? {
        var photo: CGImage?
        if let pageImage, let data = await download(pageImage, referer: referer, session: session) {
            photo = CoverRenderer.decode(data)
        }
        if photo == nil, let firstArticleImage { photo = CoverRenderer.decode(firstArticleImage) }
        return CoverRenderer.jpeg(title: title, site: site, image: photo)
    }

    static func download(_ url: URL, referer: URL?, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(WebExtractor.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }

    // MARK: - Images

    static func downloadAndConvert(_ urls: [URL], referer: URL?, session: URLSession) async -> [URL: Data] {
        let unique = Array(Set(urls))
        var results: [URL: Data] = [:]
        let maxConcurrent = 6
        await withTaskGroup(of: (URL, Data?).self) { group in
            var next = 0
            func enqueue() {
                guard next < unique.count else { return }
                let url = unique[next]
                next += 1
                group.addTask {
                    guard let data = await download(url, referer: referer, session: session) else { return (url, nil) }
                    return (url, ImageProcessor.greyscaleJPEG(from: data))
                }
            }
            for _ in 0..<maxConcurrent { enqueue() }
            for await (url, data) in group {
                if let data { results[url] = data }
                enqueue()
            }
        }
        return results
    }
}
