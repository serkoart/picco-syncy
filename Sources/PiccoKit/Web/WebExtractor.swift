import Foundation
import WebKit

/// What extract.js returns for one page.
public struct ExtractedPage: Decodable, Sendable {
    public var url: String
    public var title: String
    public var author: String
    public var site: String
    public var domain: String
    public var published: String
    public var language: String
    public var description: String
    public var wordCount: Int
    public var imageCount: Int
    /// The page's main image URL (og:image or similar), if any. Used for the cover.
    public var image: String? = nil
    /// A `<div xmlns="http://www.w3.org/1999/xhtml">` holding the cleaned article.
    /// Images carry `data-picco-src` with the URL to download.
    public var html: String
}

public enum ExtractionError: LocalizedError {
    case loadFailed(String)
    case timedOut
    case scriptFailed(String)
    case noContent

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let why): "Couldn't load the page: \(why)"
        case .timedOut: "The page took too long to load."
        case .scriptFailed(let why): "Article extraction failed: \(why)"
        case .noContent: "No readable article was found on this page."
        }
    }
}

/// Loads a page in an off-screen WKWebView and runs Defuddle + extract.js on it.
/// Must be used on the main thread, with a running main run loop (an app, or the CLI's NSApplication).
@MainActor
public final class WebExtractor: NSObject, WKNavigationDelegate {
    /// A Safari user agent, so sites serve the same page Safari would get.
    public nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public override init() { super.init() }

    /// Fetches and renders a URL (page JavaScript enabled, so client-rendered sites work).
    public func extract(url: URL, includeImages: Bool, timeout: TimeInterval = 45) async throws -> ExtractedPage {
        let view = makeWebView(allowPageScripts: true)
        defer { tearDown() }
        try await load(timeout: timeout) { view.load(URLRequest(url: url)) }
        // Give client-side rendering a moment to settle.
        try? await Task.sleep(for: .milliseconds(1200))
        return try await run(in: view, includeImages: includeImages)
    }

    /// Extracts from HTML captured elsewhere (e.g. Safari's share extension).
    /// Page scripts are disabled: the captured DOM is already rendered.
    public func extract(html: String, baseURL: URL, includeImages: Bool, timeout: TimeInterval = 30) async throws
        -> ExtractedPage
    {
        let view = makeWebView(allowPageScripts: false)
        defer { tearDown() }
        try await load(timeout: timeout) { view.loadHTMLString(html, baseURL: baseURL) }
        return try await run(in: view, includeImages: includeImages)
    }

    // MARK: - Internals

    private func makeWebView(allowPageScripts: Bool) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = allowPageScripts
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    private func load(timeout: TimeInterval, start: () -> Void) async throws {
        let timeoutTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.webView?.stopLoading()
            self?.finishLoad(.failure(ExtractionError.timedOut))
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            start()
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        c.resume(with: result)
    }

    private func run(in view: WKWebView, includeImages: Bool) async throws -> ExtractedPage {
        let world = WKContentWorld.world(name: "picco-extract")
        do {
            _ = try await view.evaluateJavaScript(Self.script("defuddle") + "\n;true;", in: nil, contentWorld: world)
            _ = try await view.evaluateJavaScript(Self.script("extract"), in: nil, contentWorld: world)
        } catch {
            throw ExtractionError.scriptFailed(error.localizedDescription)
        }
        let value: Any?
        do {
            value = try await view.callAsyncJavaScript(
                "return window.__piccoExtract({ includeImages: \(includeImages ? "true" : "false") });",
                in: nil, contentWorld: world)
        } catch {
            throw ExtractionError.scriptFailed(error.localizedDescription)
        }
        guard let json = value as? String, let data = json.data(using: .utf8) else {
            throw ExtractionError.scriptFailed("unexpected result")
        }
        let page = try JSONDecoder().decode(ExtractedPage.self, from: data)
        if page.wordCount < 20 && page.imageCount == 0 { throw ExtractionError.noContent }
        return page
    }

    private static func script(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("Missing bundled \(name).js") }
        return source
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(ExtractionError.loadFailed(error.localizedDescription)))
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        finishLoad(.failure(ExtractionError.loadFailed(error.localizedDescription)))
    }

    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, navigationResponse.isForMainFrame,
            http.statusCode >= 400
        {
            finishLoad(.failure(ExtractionError.loadFailed("HTTP \(http.statusCode)")))
            return .cancel
        }
        return .allow
    }
}
