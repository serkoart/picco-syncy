import Foundation

/// Everything needed to write one EPUB. Chapter bodies are XHTML fragments that go inside `<body>`.
public struct EPUBDocument: Sendable {
    public struct Section: Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public struct Chapter: Sendable {
        public var title: String
        public var bodyXHTML: String
        public var sections: [Section]
        public init(title: String, bodyXHTML: String, sections: [Section] = []) {
            self.title = title; self.bodyXHTML = bodyXHTML; self.sections = sections
        }
    }

    public struct Image: Sendable {
        /// Path relative to the chapter files, e.g. `images/img1.jpg`.
        public var href: String
        public var data: Data
        public var mediaType: String
        public init(href: String, data: Data, mediaType: String = "image/jpeg") {
            self.href = href; self.data = data; self.mediaType = mediaType
        }
    }

    public var identifier: UUID
    public var title: String
    public var author: String
    public var publisher: String?
    public var language: String
    public var source: URL?
    /// `YYYY-MM-DD` or a full ISO 8601 date, if known.
    public var date: String?
    public var chapters: [Chapter]
    public var images: [Image]
    public var modified: Date

    public init(
        identifier: UUID = UUID(), title: String, author: String, publisher: String? = nil,
        language: String = "en", source: URL? = nil, date: String? = nil,
        chapters: [Chapter], images: [Image] = [], modified: Date = Date()
    ) {
        self.identifier = identifier; self.title = title; self.author = author
        self.publisher = publisher; self.language = language; self.source = source
        self.date = date; self.chapters = chapters; self.images = images; self.modified = modified
    }
}

public enum EPUBBuilder {
    /// Builds an EPUB 3 archive, with an EPUB 2 NCX alongside for older reading engines.
    public static func build(_ doc: EPUBDocument) -> Data {
        var zip = ZipWriter(date: doc.modified)
        zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        zip.add("META-INF/container.xml", Data(containerXML.utf8))
        zip.add("OEBPS/content.opf", Data(packageOPF(doc).utf8))
        zip.add("OEBPS/nav.xhtml", Data(navXHTML(doc).utf8))
        zip.add("OEBPS/toc.ncx", Data(tocNCX(doc).utf8))
        zip.add("OEBPS/style.css", Data(stylesheet.utf8))
        for (i, chapter) in doc.chapters.enumerated() {
            zip.add("OEBPS/\(chapterFile(i))", Data(chapterXHTML(chapter, lang: doc.language).utf8))
        }
        for image in doc.images {
            zip.add("OEBPS/\(image.href)", image.data, compress: false)
        }
        return zip.finish()
    }

    static func chapterFile(_ index: Int) -> String { "c\(index + 1).xhtml" }

    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    static var stylesheet: String {
        if let url = Bundle.module.url(forResource: "style", withExtension: "css"),
            let css = try? String(contentsOf: url, encoding: .utf8)
        {
            return css
        }
        return "img { max-width: 100%; }"
    }

    static func packageOPF(_ doc: EPUBDocument) -> String {
        var meta = """
                <dc:identifier id="uid">urn:uuid:\(doc.identifier.uuidString.lowercased())</dc:identifier>
                <dc:title>\(xml(doc.title))</dc:title>
                <dc:creator>\(xml(doc.author))</dc:creator>
                <dc:language>\(xml(doc.language))</dc:language>
            """
        if let publisher = doc.publisher { meta += "\n    <dc:publisher>\(xml(publisher))</dc:publisher>" }
        if let source = doc.source { meta += "\n    <dc:source>\(xml(source.absoluteString))</dc:source>" }
        if let date = doc.date { meta += "\n    <dc:date>\(xml(date))</dc:date>" }
        let modified = ISO8601DateFormatter().string(from: doc.modified)
        meta += "\n    <meta property=\"dcterms:modified\">\(modified)</meta>"

        var manifest = """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
            """
        var spine = ""
        for i in doc.chapters.indices {
            manifest += "\n    <item id=\"c\(i + 1)\" href=\"\(chapterFile(i))\" media-type=\"application/xhtml+xml\"/>"
            spine += "\n    <itemref idref=\"c\(i + 1)\"/>"
        }
        for (i, image) in doc.images.enumerated() {
            manifest += "\n    <item id=\"img\(i + 1)\" href=\"\(xml(image.href))\" media-type=\"\(image.mediaType)\"/>"
        }

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(xml(doc.language))">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(meta)
              </metadata>
              <manifest>
            \(manifest)
              </manifest>
              <spine toc="ncx">\(spine)
              </spine>
            </package>
            """
    }

    static func navXHTML(_ doc: EPUBDocument) -> String {
        var items = ""
        for (i, chapter) in doc.chapters.enumerated() {
            let file = chapterFile(i)
            items += "\n      <li><a href=\"\(file)\">\(xml(chapter.title))</a>"
            if !chapter.sections.isEmpty {
                items += "\n        <ol>"
                for s in chapter.sections {
                    items += "\n          <li><a href=\"\(file)#\(xml(s.id))\">\(xml(s.title))</a></li>"
                }
                items += "\n        </ol>"
            }
            items += "</li>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(xml(doc.language))" lang="\(xml(doc.language))">
            <head><meta charset="UTF-8"/><title>Contents</title></head>
            <body>
              <nav epub:type="toc" id="toc">
                <h1>Contents</h1>
                <ol>\(items)
                </ol>
              </nav>
            </body>
            </html>
            """
    }

    static func tocNCX(_ doc: EPUBDocument) -> String {
        var points = ""
        var order = 0
        for (i, chapter) in doc.chapters.enumerated() {
            let file = chapterFile(i)
            order += 1
            points += "\n    <navPoint id=\"np\(order)\" playOrder=\"\(order)\"><navLabel><text>\(xml(chapter.title))</text></navLabel><content src=\"\(file)\"/>"
            for s in chapter.sections {
                order += 1
                points += "\n      <navPoint id=\"np\(order)\" playOrder=\"\(order)\"><navLabel><text>\(xml(s.title))</text></navLabel><content src=\"\(file)#\(xml(s.id))\"/></navPoint>"
            }
            points += "\n    </navPoint>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="urn:uuid:\(doc.identifier.uuidString.lowercased())"/>
                <meta name="dtb:depth" content="2"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
              </head>
              <docTitle><text>\(xml(doc.title))</text></docTitle>
              <navMap>\(points)
              </navMap>
            </ncx>
            """
    }

    static func chapterXHTML(_ chapter: EPUBDocument.Chapter, lang: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(xml(lang))" lang="\(xml(lang))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(xml(chapter.title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(chapter.bodyXHTML)
        </body>
        </html>
        """
    }
}

/// Escapes text for use in XML content and attribute values.
func xml(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        case "\t", "\n", "\r": out.unicodeScalars.append(ch)
        default:
            // Drop characters XML 1.0 forbids.
            if ch.value < 0x20 || (0xFFFE...0xFFFF).contains(ch.value) { continue }
            out.unicodeScalars.append(ch)
        }
    }
    return out
}
