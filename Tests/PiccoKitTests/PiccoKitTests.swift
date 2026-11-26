import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PiccoKit

// MARK: - Helpers

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "picco-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs /usr/bin/unzip with the given arguments and returns (exit code, stdout).
func unzip(_ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/unzip")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

/// A folder laid out like a mounted Picco.
func fakeDevice() throws -> PiccoDevice {
    let root = try tempDir()
    let fm = FileManager.default
    try fm.createDirectory(at: root.appending(path: "books"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appending(path: ".onyx/acct1/local/books"), withIntermediateDirectories: true)
    return try PiccoDevice(root: root)
}

func sampleDocument(images: [EPUBDocument.Image] = []) -> EPUBDocument {
    EPUBDocument(
        title: "A <Test> & Title", author: "Jane Doe", publisher: "Example", source: URL(string: "https://example.com/a"),
        date: "2026-11-01",
        chapters: [.init(
            title: "A <Test> & Title",
            bodyXHTML: "<h1>A &lt;Test&gt; &amp; Title</h1><h2 id=\"s1\">Part one</h2><p>Hello.</p>",
            sections: [.init(id: "s1", title: "Part one")])],
        images: images)
}

// MARK: - ZIP / EPUB

@Suite struct ZipTests {
    @Test func crc32MatchesStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func archiveIsValidAndMimetypeComesFirstUncompressed() throws {
        let epub = EPUBBuilder.build(sampleDocument())
        let file = try tempDir().appending(path: "t.epub")
        try epub.write(to: file)

        let (testCode, _) = try unzip(["-tq", file.path])
        #expect(testCode == 0)

        // ZIP local header: name starts at byte 30; method is bytes 8-9.
        #expect(epub.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(epub[8] == 0 && epub[9] == 0)
        #expect(String(decoding: epub[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: epub[38..<58], as: UTF8.self) == "application/epub+zip")
    }

    @Test func allXMLPartsAreWellFormedAndMetadataIsEscaped() throws {
        let jpeg = try #require(ImageProcessor.greyscaleJPEG(from: makePNG(width: 200, height: 100)))
        let doc = sampleDocument(images: [.init(href: "images/img1.jpg", data: jpeg)])
        let dir = try tempDir()
        let file = dir.appending(path: "t.epub")
        try EPUBBuilder.build(doc).write(to: file)
        let (code, _) = try unzip(["-q", file.path, "-d", dir.appending(path: "x").path])
        #expect(code == 0)

        for part in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/c1.xhtml"] {
            let data = try Data(contentsOf: dir.appending(path: "x/\(part)"))
            #expect(throws: Never.self, "\(part) should parse") { _ = try XMLDocument(data: data) }
        }
        let opf = try String(contentsOf: dir.appending(path: "x/OEBPS/content.opf"), encoding: .utf8)
        #expect(opf.contains("<dc:title>A &lt;Test&gt; &amp; Title</dc:title>"))
        #expect(opf.contains("<dc:creator>Jane Doe</dc:creator>"))
        #expect(opf.contains("href=\"images/img1.jpg\" media-type=\"image/jpeg\""))
        let nav = try String(contentsOf: dir.appending(path: "x/OEBPS/nav.xhtml"), encoding: .utf8)
        #expect(nav.contains("c1.xhtml#s1"))
    }

    @Test func xmlEscapingDropsForbiddenControlCharacters() {
        #expect(xml("a\u{0001}b<c>&\"'") == "ab&lt;c&gt;&amp;&quot;&apos;")
    }
}

// MARK: - Images

func makePNG(width: Int, height: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@Suite struct ImageTests {
    @Test func largeColourImageBecomesGreyAndScreenWidth() throws {
        let jpeg = try #require(ImageProcessor.greyscaleJPEG(from: makePNG(width: 1600, height: 800)))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 480)
        #expect(image.height == 240)
        #expect(image.colorSpace?.model == .monochrome)
    }

    @Test func smallImagesAreNotUpscaled() throws {
        let jpeg = try #require(ImageProcessor.greyscaleJPEG(from: makePNG(width: 300, height: 200)))
        let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil))
        #expect(image.width == 300)
    }

    @Test func iconsAndGarbageAreRejected() {
        #expect(ImageProcessor.greyscaleJPEG(from: makePNG(width: 32, height: 32)) == nil)
        #expect(ImageProcessor.greyscaleJPEG(from: Data("not an image".utf8)) == nil)
    }
}

// MARK: - File names

@Suite struct FileNamerTests {
    @Test func removesCharactersFAT32Rejects() {
        #expect(FileNamer.fileName(title: "Q&A: Why? <Really> \"yes\" / no | maybe*", site: nil)
            == "Q&A - Why Really yes no maybe.epub")
    }

    @Test func appendsSiteUnlessTitleAlreadyHasIt() {
        #expect(FileNamer.fileName(title: "Big Story", site: "The Atlantic") == "Big Story — The Atlantic.epub")
        #expect(FileNamer.fileName(title: "Big Story | The Atlantic", site: "The Atlantic") == "Big Story The Atlantic.epub")
    }

    @Test func noHiddenOrTrailingDotNames() {
        #expect(FileNamer.fileName(title: "...hidden...", site: nil) == "hidden.epub")
        #expect(FileNamer.fileName(title: "   ", site: nil) == "Untitled.epub")
    }

    @Test func longTitlesAreCutOnACharacterBoundary() {
        let name = FileNamer.fileName(title: String(repeating: "é", count: 400), site: nil)
        let stem = (name as NSString).deletingPathExtension
        #expect(stem.utf8.count <= FileNamer.maxStemBytes)
        #expect(stem.hasSuffix("…"))
    }

    @Test func uniqueIsCaseInsensitive() {
        #expect(FileNamer.unique("a.epub", existing: ["A.EPUB"]) == "a (2).epub")
        #expect(FileNamer.unique("a.epub", existing: ["a.epub", "a (2).epub"]) == "a (3).epub")
        #expect(FileNamer.unique("b.epub", existing: ["a.epub"]) == "b.epub")
    }
}

// MARK: - Device and sync

@Suite struct DeviceTests {
    @Test func parsesRealStateFiles() throws {
        let (path, p) = try #require(PiccoDevice.parseState(try fixture("state-epub.json")))
        #expect(path == "/books/Picco Test EPUB.epub")
        #expect(p.finished)
        #expect(p.percent == 100)
        #expect(p.lastOpened == Date(timeIntervalSince1970: 1_795_658_196))

        let (path2, p2) = try #require(PiccoDevice.parseState(try fixture("state-opub.json")))
        #expect(path2 == "embedded://The Odyssey.opub")
        #expect(!p2.finished)
        #expect(p2.percent == 5.6)
    }

    @Test func garbageStateIsIgnored() {
        #expect(PiccoDevice.parseState(Data("{}".utf8)) == nil)
        #expect(PiccoDevice.parseState(Data("not json".utf8)) == nil)
    }

    @Test func tidyRemovesAppleDoubleFilesThatFileManagerHides() throws {
        let device = try fakeDevice()
        try FileManager.default.createDirectory(at: device.articlesFolder, withIntermediateDirectories: true)
        let book = device.articlesFolder.appending(path: "Book.epub")
        try Data("epub".utf8).write(to: book)
        try Data("meta".utf8).write(to: device.articlesFolder.appending(path: "._Book.epub"))
        try Data("meta".utf8).write(to: device.root.appending(path: "._.metadata_never_index"))
        device.tidy()
        #expect(PiccoDevice.rawDirectoryNames(device.articlesFolder) == ["Book.epub"])
        #expect(!PiccoDevice.rawDirectoryNames(device.root).contains("._.metadata_never_index"))
        #expect(PiccoDevice.rawDirectoryNames(device.root).contains(".metadata_never_index"))
    }

    @Test func rejectsFoldersThatAreNotAPicco() throws {
        #expect(throws: DeviceError.self) { try PiccoDevice(root: try tempDir()) }
    }

    @Test func syncDeliversQueuedItemsThenReadsProgress() throws {
        let device = try fakeDevice()
        let outbox = Outbox(root: try tempDir())
        let epub = EPUBBuilder.build(sampleDocument())
        let item = OutboxItem(title: "Big Story", author: "Jane", site: "Example", source: "https://example.com/a", epubBytes: epub.count)
        try outbox.add(epub: epub, item: item)
        // A same-named file already on the device must not be overwritten.
        try FileManager.default.createDirectory(at: device.articlesFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: device.articlesFolder.appending(path: "Big Story — Example.epub"))

        let first = Syncer.sync(outbox: outbox, device: device)
        #expect(first.delivered.count == 1)
        #expect(first.failures.isEmpty)
        let delivered = try #require(outbox.items().first)
        #expect(delivered.state == .delivered)
        #expect(delivered.deviceFileName == "Big Story — Example (2).epub")
        #expect(delivered.devicePath == "/books/Articles/Big Story — Example (2).epub")
        let onDevice = try Data(contentsOf: device.articlesFolder.appending(path: "Big Story — Example (2).epub"))
        #expect(onDevice == epub)
        let names = PiccoDevice.rawDirectoryNames(device.articlesFolder)
        #expect(!names.contains { $0.hasPrefix("._") || $0.hasSuffix(".tmp") })
        #expect(FileManager.default.fileExists(atPath: device.root.appending(path: ".metadata_never_index").path))

        // The Picco records progress; the next sync reads it back and delivers nothing new.
        let stateDir = device.root.appending(path: ".onyx/acct1/local/books/1234")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let state: [String: Any] = [
            "version": 1, "path": delivered.devicePath!, "progressPercent": 42.5, "finished": false,
            "lastOpenedAt": 1_795_658_196,
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: stateDir.appending(path: "state.json"))

        let second = Syncer.sync(outbox: outbox, device: device)
        #expect(second.delivered.isEmpty)
        #expect(second.progressUpdated.count == 1)
        #expect(outbox.items().first?.progress == ReadingProgress(
            percent: 42.5, finished: false, lastOpened: Date(timeIntervalSince1970: 1_795_658_196)))

        // Unchanged progress isn't reported again.
        #expect(Syncer.sync(outbox: outbox, device: device).progressUpdated.isEmpty)
    }
}

// MARK: - Article assembly

@Suite struct AssemblerTests {
    func page(html: String, title: String = "Big Story") -> ExtractedPage {
        ExtractedPage(
            url: "https://example.com/story", title: title, author: "", site: "Example", domain: "example.com",
            published: "2026-11-03T10:00:00Z", language: "en", description: "", wordCount: 100, imageCount: 0,
            html: "<div xmlns=\"http://www.w3.org/1999/xhtml\">\(html)</div>")
    }

    @Test func dropsDuplicateHeadlineDemotesH1AndBuildsSections() async throws {
        let article = try await ArticleAssembler.assemble(page(html:
            "<div><h1>Big Story!</h1><p>Intro.</p><h1>Inner title</h1><h2>Next part</h2><p>More.</p></div>"))
        let body = try #require(article.document.chapters.first?.bodyXHTML)
        #expect(body.components(separatedBy: "<h1>").count == 2, "only our own title should be an h1")
        #expect(body.contains("<h2 id=\"picco-s1\">Inner title</h2>"))
        #expect(article.document.chapters[0].sections.map(\.title) == ["Inner title", "Next part"])
        #expect(article.author == "Example", "no byline falls back to the site name")
        #expect(article.document.date == "2026-11-03")
        #expect(!body.contains("xmlns"))
        // The whole chapter must still be well-formed XML.
        let chapter = EPUBBuilder.chapterXHTML(article.document.chapters[0], lang: "en")
        #expect(throws: Never.self) { _ = try XMLDocument(xmlString: chapter) }
    }

    @Test func imagesThatFailToDownloadAreRemoved() async throws {
        let article = try await ArticleAssembler.assemble(page(html:
            "<p>Text</p><figure><img data-picco-src=\"https://127.0.0.1:9/missing.jpg\" alt=\"\"/><figcaption>A caption</figcaption></figure>"))
        let body = article.document.chapters[0].bodyXHTML
        #expect(article.imagesKept == 0)
        #expect(article.imagesDropped == 1)
        #expect(!body.contains("<img"))
        #expect(!body.contains("<figure"))
        #expect(body.contains("<p>A caption</p>"), "an orphaned caption is kept as text")
    }
}
