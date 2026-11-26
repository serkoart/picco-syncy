import PiccoKit
import SwiftUI

/// The panel that drops down from the menu-bar icon.
struct MenuContent: View {
    let model: AppModel
    @State private var link = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            addLink
            messages
            Divider()
            lists
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Picco Syncy").font(.headline)
                Spacer()
                DeviceBadge(connected: model.device != nil)
            }
            if model.device != nil {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isSyncing { ProgressView().controlSize(.small) }
                            Text(model.isSyncing ? "Syncing…" : "Sync Now")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await model.eject() }
                    } label: {
                        Label("Eject", systemImage: "eject")
                    }
                    .help("Eject the Picco so it's safe to unplug")
                }
                .disabled(model.isSyncing)
            } else {
                Text("To sync, plug in the Picco and tap Transfer → USB → Start USB-C transfer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = model.lastSync {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addLink: some View {
        HStack(spacing: 6) {
            TextField("Paste a link to send…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendLink)
                .disabled(model.isSending)
            if model.isSending {
                ProgressView().controlSize(.small)
            } else {
                Button("Add", action: sendLink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let message = model.message {
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var lists: some View {
        if model.waiting.isEmpty && model.onPicco.isEmpty {
            Text("Nothing here yet. Paste a link above, or use `picco send <url>` in Terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.waiting.isEmpty {
                        section("Waiting", count: model.waiting.count) {
                            ForEach(model.waiting) { item in
                                WaitingRow(item: item) { model.remove(item) }
                            }
                        }
                    }
                    if !model.onPicco.isEmpty {
                        section("On Picco", count: model.onPicco.count) {
                            ForEach(model.onPicco.prefix(30)) { item in DeliveredRow(item: item) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Outbox") { model.openOutboxFolder() }
            Spacer()
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) (\(count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func sendLink() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !model.isSending else { return }
        Task {
            await model.send(link: text)
            if model.errorMessage == nil { link = "" }
        }
    }
}

// MARK: - Rows

struct DeviceBadge: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(connected ? "Picco connected" : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct WaitingRow: View {
    let item: OutboxItem
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ItemText(item: item, detail: ByteCountFormatter.string(fromByteCount: Int64(item.epubBytes), countStyle: .file))
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the outbox")
            .accessibilityLabel("Remove \(item.title)")
        }
    }
}

struct DeliveredRow: View {
    let item: OutboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ItemText(item: item, detail: nil)
            if let p = item.progress, p.finished {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let p = item.progress, p.percent > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: min(p.percent, 100), total: 100)
                        .progressViewStyle(.linear)
                    Text("\(Int(p.percent.rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not opened yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Title and site; clicking opens the original page.
struct ItemText: View {
    let item: OutboxItem
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.callout)
                .lineLimit(2)
            Text([item.site, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let source = item.source, let url = URL(string: source) { NSWorkspace.shared.open(url) }
        }
        .help(item.source ?? "")
    }
}
