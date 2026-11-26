import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Send to Picco" sheet in the Share menu.
///
/// It only captures the page and drops a job into the shared inbox, then wakes the app, which does the
/// converting. Extensions are short-lived and sandboxed, so the real work belongs in the app.
final class ShareViewController: NSViewController {
    private let state = ShareState()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let sheet = ShareSheet(
            state: state,
            send: { [weak self] in self?.send() },
            cancel: { [weak self] in self?.cancel() })
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 170)
        view = host
        loadSharedItem()
    }

    // MARK: - Reading what was shared

    private func loadSharedItem() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }

        // Safari: the page as rendered, via Preprocess.js.
        if let page = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) {
            page.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { [weak self] item, _ in
                let dict = item as? NSDictionary
                let results = dict?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                let url = (results?["url"] as? String).flatMap(URL.init(string:))
                let title = results?["title"] as? String
                let html = results?["html"] as? String
                DispatchQueue.main.async {
                    if let url { self?.state.loaded(url: url, title: title, html: html) }
                    else { self?.loadURL(from: providers) }
                }
            }
            return
        }
        loadURL(from: providers)
    }

    /// Other apps (and Safari, if the page script didn't run) share just the address.
    private func loadURL(from providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) })
        else {
            state.fail("There’s no web page to send.")
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            var url = item as? URL
            if url == nil, let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            DispatchQueue.main.async {
                guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    self?.state.fail("Only web pages can be sent to the Picco.")
                    return
                }
                self?.state.loaded(url: url, title: nil, html: nil)
            }
        }
    }

    // MARK: - Actions

    private func send() {
        guard let url = state.url else { return }
        let job = ShareJob(
            id: UUID(), url: url.absoluteString, title: state.title, includeImages: state.includeImages,
            hasHTML: state.html != nil, createdAt: Date())
        do {
            try ShareInbox.write(job, html: state.html)
            ShareInbox.defaults?.set(state.includeImages, forKey: ShareInbox.includeImagesKey)
        } catch {
            state.fail("Couldn’t hand the page to Picco Syncy: \(error.localizedDescription)")
            return
        }
        // Wake (or launch) Picco Syncy so it converts the page now.
        NSWorkspace.shared.open(ShareInbox.openURL)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

// MARK: - Sheet

final class ShareState: ObservableObject {
    @Published var url: URL?
    @Published var title: String?
    @Published var html: String?
    @Published var includeImages = ShareInbox.defaults?.object(forKey: ShareInbox.includeImagesKey) as? Bool ?? true
    @Published var error: String?

    func loaded(url: URL, title: String?, html: String?) {
        self.url = url
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.html = html
    }

    func fail(_ message: String) { error = message }
}

struct ShareSheet: View {
    @ObservedObject var state: ShareState
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Send to Picco", systemImage: "book.closed")
                .font(.headline)

            if let error = state.error {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let url = state.url {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title ?? url.host() ?? url.absoluteString)
                        .lineLimit(2)
                    Text(url.host() ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Include images", isOn: $state.includeImages)
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.url == nil || state.error != nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
