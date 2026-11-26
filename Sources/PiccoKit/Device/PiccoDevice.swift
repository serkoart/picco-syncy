import AppKit
import Foundation

/// Reading progress the Picco records for one book.
public struct ReadingProgress: Codable, Sendable, Equatable {
    public var percent: Double
    public var finished: Bool
    public var lastOpened: Date?

    public init(percent: Double, finished: Bool, lastOpened: Date?) {
        self.percent = percent; self.finished = finished; self.lastOpened = lastOpened
    }
}

public enum DeviceError: LocalizedError {
    case notAPicco(URL)
    case writeFailed(String)
    case ejectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAPicco(let url): "\(url.path) doesn't look like a Picco (no books/ and .onyx/ folders)."
        case .writeFailed(let why): "Couldn't write to the Picco: \(why)"
        case .ejectFailed(let why): "Couldn't eject the Picco: \(why)"
        }
    }
}

/// A mounted Picco (or a folder laid out like one, for tests).
///
/// We only ever write inside `books/Articles/` (plus a `.metadata_never_index` marker at the root),
/// and only ever read `.onyx/`. The `.onyx/` layout is undocumented, so reads fail soft.
public struct PiccoDevice: Sendable {
    public static let volumeName = "BOOX TILE"
    public static let articlesPath = "books/Articles"

    public let root: URL

    public init(root: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.appending(path: "books").path, isDirectory: &isDir), isDir.boolValue,
            fm.fileExists(atPath: root.appending(path: ".onyx").path, isDirectory: &isDir), isDir.boolValue
        else { throw DeviceError.notAPicco(root) }
        self.root = root
    }

    /// The mounted Picco, if there is one.
    public static func findMounted() -> PiccoDevice? {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            if name == volumeName, let device = try? PiccoDevice(root: url) { return device }
        }
        return nil
    }

    public var articlesFolder: URL { root.appending(path: Self.articlesPath, directoryHint: .isDirectory) }

    /// File names currently in books/Articles.
    public func existingArticleNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: articlesFolder.path)) ?? []
        return Set(names)
    }

    /// Copies an EPUB into books/Articles under `fileName`. Returns the device path the Picco will record
    /// (e.g. `/books/Articles/Title.epub`).
    ///
    /// The file is written under a temporary hidden name, flushed, then renamed, so the Picco never sees a
    /// half-written book. Writing raw data (not copying a file) keeps macOS from adding `._` metadata files.
    @discardableResult
    public func deliver(epub: Data, fileName: String) throws -> String {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: articlesFolder, withIntermediateDirectories: true)
            let temp = articlesFolder.appending(path: ".picco-\(UUID().uuidString).tmp")
            let final = articlesFolder.appending(path: fileName)
            fm.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: epub)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: temp, to: final)
        } catch {
            throw DeviceError.writeFailed(error.localizedDescription)
        }
        return "/" + Self.articlesPath + "/" + fileName
    }

    /// Removes macOS clutter from our folder and stops Spotlight indexing the device.
    ///
    /// macOS tags every file a process creates with `com.apple.provenance`, which can't be removed. On FAT32
    /// that tag lives in a `._<name>` AppleDouble file next to the book, and the Picco might list it as a
    /// broken book. `FileManager` hides `._` files on FAT volumes, so we list with readdir and unlink them,
    /// which also drops the tag.
    public func tidy() {
        let fm = FileManager.default
        let marker = root.appending(path: ".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: Data()) }

        for name in Self.rawDirectoryNames(articlesFolder)
        where name.hasPrefix("._") || name == ".DS_Store" || (name.hasPrefix(".picco-") && name.hasSuffix(".tmp")) {
            unlink(articlesFolder.appending(path: name).path)
        }
        for name in Self.rawDirectoryNames(root) where name == "._.metadata_never_index" {
            unlink(root.appending(path: name).path)
        }
    }

    /// Directory entries exactly as the file system reports them, including AppleDouble `._` files.
    static func rawDirectoryNames(_ dir: URL) -> [String] {
        guard let d = opendir(dir.path) else { return [] }
        defer { closedir(d) }
        var names: [String] = []
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Reads every `.onyx/<account>/local/books/<id>/state.json`, keyed by the book's device path.
    public func readProgress() -> [String: ReadingProgress] {
        let fm = FileManager.default
        let onyx = root.appending(path: ".onyx")
        var result: [String: ReadingProgress] = [:]
        let accounts = (try? fm.contentsOfDirectory(atPath: onyx.path)) ?? []
        for account in accounts {
            let books = onyx.appending(path: account).appending(path: "local/books")
            for id in (try? fm.contentsOfDirectory(atPath: books.path)) ?? [] {
                let file = books.appending(path: id).appending(path: "state.json")
                guard let data = try? Data(contentsOf: file),
                    let (path, progress) = Self.parseState(data)
                else { continue }
                // If a book appears under more than one account, keep the most recently opened.
                if let existing = result[path], (existing.lastOpened ?? .distantPast) > (progress.lastOpened ?? .distantPast) {
                    continue
                }
                result[path] = progress
            }
        }
        return result
    }

    /// Parses one state.json. Unknown fields are ignored; missing ones fall back to "not started".
    static func parseState(_ data: Data) -> (String, ReadingProgress)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = obj["path"] as? String
        else { return nil }
        let percent = (obj["progressPercent"] as? NSNumber)?.doubleValue ?? 0
        let finished = (obj["finished"] as? Bool) ?? false
        let opened = (obj["lastOpenedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return (path, ReadingProgress(percent: percent, finished: finished, lastOpened: opened))
    }

    /// Ejects the Picco. NSWorkspace's eject has failed with "busy" (-47) on this volume even with nothing
    /// open, while `diskutil eject` succeeds, so we fall back to diskutil with a few short retries.
    @MainActor
    public func eject() async throws {
        if (try? NSWorkspace.shared.unmountAndEjectDevice(at: root)) != nil { return }
        var lastError = "unknown error"
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            let (status, output) = await Self.runDiskutil(["eject", root.path])
            if status == 0 { return }
            lastError = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DeviceError.ejectFailed(lastError)
    }

    private static func runDiskutil(_ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/diskutil")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (p.terminationStatus, String(decoding: out, as: UTF8.self)))
            }
            do { try process.run() } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
