import Foundation

/// Builds file names that are safe on the Picco's FAT32 volume.
public enum FileNamer {
    /// Characters FAT32 (and the BOOX library) can't take.
    static let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
    static let maxStemBytes = 180

    /// "Title — Site.epub", cleaned and shortened.
    public static func fileName(title: String, site: String?) -> String {
        var stem = clean(title)
        if let site, !site.isEmpty {
            let s = clean(site)
            if !s.isEmpty, !stem.localizedCaseInsensitiveContains(s) { stem += " — " + s }
        }
        if stem.isEmpty { stem = "Untitled" }
        return truncate(stem, maxBytes: maxStemBytes) + ".epub"
    }

    /// Returns `name`, or `name (2)`, `name (3)`… — compared case-insensitively, as FAT32 does.
    public static func unique(_ name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    static func clean(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar == ":" { out += " -" }
            else if illegal.contains(scalar) { out += " " }
            else { out.unicodeScalars.append(scalar) }
        }
        out = out.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        // No leading dots (hidden files), no trailing dots or spaces (FAT32 strips them).
        while out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func truncate(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        let ellipsis = "…"
        let budget = maxBytes - ellipsis.utf8.count
        var out = ""
        for ch in s {
            if out.utf8.count + String(ch).utf8.count > budget { break }
            out.append(ch)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasSuffix(".") || out.hasSuffix("—") || out.hasSuffix("-") {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out + ellipsis
    }
}
