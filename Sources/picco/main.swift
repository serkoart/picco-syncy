import AppKit
import PiccoKit

// WKWebView needs a real main run loop, so the CLI runs inside an invisible NSApplication.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let code = await CLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
app.run()

@MainActor
enum CLI {
    static let usage = """
        picco — send articles to a BOOX Picco

        USAGE
          picco send <url> [--no-images] [--force]   Convert a web page and add it to the outbox
          picco send --html <file> --url <url>       Convert saved HTML (as the Share extension will)
          picco epub <url> -o <file.epub> [--no-images]  Convert to an EPUB file only (for previewing)
          picco list                                 Show the outbox and reading progress
          picco sync [--device <path>] [--no-eject]  Deliver queued items to a mounted Picco and read progress
          picco status                               Is a Picco mounted?

        The outbox lives in ~/Library/Application Support/PiccoSync (override with PICCO_HOME).
        """

    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else { print(usage); return 0 }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "send": return try await send(rest)
            case "epub": return try await epub(rest)
            case "list": return list()
            case "sync": return try await sync(rest)
            case "status": return status()
            case "help", "-h", "--help": print(usage); return 0
            default:
                printError("Unknown command '\(command)'.\n\n\(usage)")
                return 64
            }
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Commands

    static func send(_ args: [String]) async throws -> Int32 {
        var opts = Options(args)
        let outbox = Outbox()
        if !opts.flag("--force"), let url = opts.target,
            let dup = outbox.items().first(where: { $0.source == url })
        {
            printError("Already in the outbox (\(dup.state.rawValue)): \(dup.title). Use --force to add it again.")
            return 1
        }
        let article = try await convert(&opts)
        let epub = EPUBBuilder.build(article.document)
        let item = OutboxItem(
            id: article.document.identifier, title: article.title, author: article.author, site: article.site,
            source: article.source?.absoluteString, epubBytes: epub.count)
        try outbox.add(epub: epub, item: item)
        print("Queued: \(article.title)")
        print("  \(article.author)\(article.site.isEmpty || article.site == article.author ? "" : " · \(article.site)")")
        print("  \(formatBytes(epub.count)), \(imageSummary(article))")
        if PiccoDevice.findMounted() != nil { print("A Picco is mounted — run `picco sync` to deliver it.") }
        return 0
    }

    static func epub(_ args: [String]) async throws -> Int32 {
        var opts = Options(args)
        guard let out = opts.value("-o") ?? opts.value("--output") else {
            printError("epub needs -o <file.epub>")
            return 64
        }
        let article = try await convert(&opts)
        let data = EPUBBuilder.build(article.document)
        try data.write(to: URL(filePath: out))
        print("Wrote \(out): \(article.title) (\(formatBytes(data.count)), \(imageSummary(article)))")
        return 0
    }

    static func list() -> Int32 {
        let items = Outbox().items()
        if items.isEmpty { print("The outbox is empty."); return 0 }
        let queued = items.filter { $0.state == .queued }
        let delivered = items.filter { $0.state == .delivered }
        if !queued.isEmpty {
            print("Waiting (\(queued.count))")
            for i in queued { print("  • \(i.title) — \(i.site) (\(formatBytes(i.epubBytes)))") }
        }
        if !delivered.isEmpty {
            print("On Picco (\(delivered.count))")
            for i in delivered {
                let progress: String
                if let p = i.progress { progress = p.finished ? "finished" : "\(Int(p.percent.rounded()))%" }
                else { progress = "not opened" }
                print("  • \(i.title) — \(progress)")
            }
        }
        return 0
    }

    static func sync(_ args: [String]) async throws -> Int32 {
        var opts = Options(args)
        let device: PiccoDevice
        if let path = opts.value("--device") {
            device = try PiccoDevice(root: URL(filePath: path, directoryHint: .isDirectory))
        } else if let found = PiccoDevice.findMounted() {
            device = found
        } else {
            printError("No Picco mounted. On the Picco: Transfer → USB → Start USB-C transfer.")
            return 1
        }
        let report = Syncer.sync(outbox: Outbox(), device: device)
        print("Delivered \(report.delivered.count)")
        for i in report.delivered { print("  + \(i.deviceFileName ?? i.title)") }
        if !report.progressUpdated.isEmpty {
            print("Progress updated for \(report.progressUpdated.count)")
            for i in report.progressUpdated {
                let p = i.progress!
                print("  ~ \(i.title): \(p.finished ? "finished" : "\(Int(p.percent.rounded()))%")")
            }
        }
        for f in report.failures { printError("  ! \(f.title): \(f.reason)") }
        if !opts.flag("--no-eject"), opts.value("--device") == nil {
            try await device.eject()
            print("Ejected — safe to unplug.")
        }
        return report.failures.isEmpty ? 0 : 1
    }

    static func status() -> Int32 {
        if let d = PiccoDevice.findMounted() {
            let progress = d.readProgress()
            print("Picco mounted at \(d.root.path) — \(d.existingArticleNames().filter { $0.hasSuffix(".epub") }.count) articles, \(progress.count) books with reading data.")
            return 0
        }
        print("No Picco mounted.")
        return 1
    }

    // MARK: - Helpers

    static func convert(_ opts: inout Options) async throws -> ArticleAssembler.Article {
        let includeImages = !opts.flag("--no-images")
        let extractor = WebExtractor()
        let page: ExtractedPage
        if let htmlPath = opts.value("--html") {
            guard let base = opts.value("--url").flatMap(URL.init(string:)) else {
                throw CLIError("--html needs --url <original page url>")
            }
            let html = try String(contentsOf: URL(filePath: htmlPath), encoding: .utf8)
            page = try await extractor.extract(html: html, baseURL: base, includeImages: includeImages)
        } else if let target = opts.target, let url = URL(string: target), url.scheme?.hasPrefix("http") == true {
            page = try await extractor.extract(url: url, includeImages: includeImages)
        } else {
            throw CLIError("Give a web address starting with http:// or https://")
        }
        return try await ArticleAssembler.assemble(page)
    }

    static func imageSummary(_ a: ArticleAssembler.Article) -> String {
        if a.imagesKept == 0 && a.imagesDropped == 0 { return "no images" }
        return "\(a.imagesKept) image\(a.imagesKept == 1 ? "" : "s")" + (a.imagesDropped > 0 ? " (\(a.imagesDropped) skipped)" : "")
    }

    static func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func printError(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

struct CLIError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Tiny argument parser: flags, `--key value` options, and one positional target.
struct Options {
    private var args: [String]
    init(_ args: [String]) { self.args = args }

    mutating func flag(_ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    mutating func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    /// The first argument that isn't an option. Read after consuming options.
    var target: String? { args.first { !$0.hasPrefix("-") } }
}
