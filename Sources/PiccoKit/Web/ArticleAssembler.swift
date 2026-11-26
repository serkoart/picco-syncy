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

        root.removeAttribute(forName: "xmlns")
        root.addAttribute(XMLNode.attribute(withName: "class", stringValue: "picco-article") as! XMLNode)
        let articleMarkup = root.xmlString(options: [.nodeCompactEmptyElement])
            .replacingOccurrences(of: " xmlns=\"http://www.w3.org/1999/xhtml\"", with: "")

        var metaParts: [String] = []
        if !page.author.isEmpty { metaParts.append(page.author) }
        if !site.isEmpty, site != page.author { metaParts.append(site) }
        if let shown = displayDate(page.published) { metaParts.append(shown) }

        var body = "<div class=\"picco-head\">\n<h1>\(xml(title))</h1>\n"
        if !metaParts.isEmpty { body += "<p class=\"picco-meta\">\(xml(metaParts.joined(separator: " · ")))</p>\n" }
        body += "</div>\n\(articleMarkup)\n"
        if let source {
            body += "<p class=\"picco-source\">Source: <a href=\"\(xml(source.absoluteString))\">\(xml(source.host() ?? source.absoluteString))</a></p>"
        }

        let language = page.language.isEmpty ? "en" : String(page.language.prefix(35))
        let document = EPUBDocument(
            title: title, author: author, publisher: site.isEmpty ? nil : site, language: language,
            source: source, date: isoDate(page.published),
            chapters: [.init(title: title, bodyXHTML: body, sections: sections)],
            images: images)
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
                    var request = URLRequest(url: url, timeoutInterval: 20)
                    request.setValue(WebExtractor.userAgent, forHTTPHeaderField: "User-Agent")
                    if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
                    guard let (data, response) = try? await session.data(for: request) else { return (url, nil) }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return (url, nil) }
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
