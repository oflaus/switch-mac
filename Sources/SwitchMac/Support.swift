import AppKit
import MTPKit
import SwiftUI
import UniformTypeIdentifiers

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useAll]
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return dateFormatter.string(from: value)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "" }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// Duração no formato mm:ss (ou h:mm:ss quando passa de uma hora).
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 60 * 60 * 24 else { return "" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s restantes" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min restantes" }
        return String(format: "%.1f h restantes", seconds / 3600)
    }

    /// Nomes vindos do aparelho podem conter caracteres que o sistema de arquivos do
    /// Mac não aceita em um componente de caminho.
    static func safeFileName(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "sem-nome" }
        if cleaned == "." || cleaned == ".." { cleaned = "sem-nome" }
        return cleaned
    }
}

enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for object: MTPObject) -> NSImage {
        if object.isFolder { return cached(key: "__folder__") { NSWorkspace.shared.icon(for: .folder) } }
        let ext = object.fileExtension
        guard !ext.isEmpty else { return cached(key: "__data__") { NSWorkspace.shared.icon(for: .data) } }
        return cached(key: ext) {
            if let type = UTType(filenameExtension: ext) { return NSWorkspace.shared.icon(for: type) }
            return NSWorkspace.shared.icon(for: .data)
        }
    }

    private static func cached(key: String, make: () -> NSImage) -> NSImage {
        if let hit = cache[key] { return hit }
        let image = make()
        cache[key] = image
        return image
    }
}

extension MTPObject {
    var kindDescription: String {
        if isFolder { return "Pasta" }
        let ext = fileExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "Documento" }
        return type.localizedDescription ?? ext.uppercased()
    }

    /// Chave de ordenação que mantém pastas antes de arquivos.
    var sortGroup: Int { isFolder ? 0 : 1 }

    /// `Table` só ordena por valores `Comparable`; `Date?` não é.
    var modifiedSortKey: Date { modified ?? .distantPast }
}

/// Faz um caminho único dentro de uma pasta, sem sobrescrever nada que já exista.
func uniqueDestination(in directory: URL, name: String) -> URL {
    let safe = Format.safeFileName(name)
    var candidate = directory.appendingPathComponent(safe)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

    let base = (safe as NSString).deletingPathExtension
    let ext = (safe as NSString).pathExtension
    var index = 2
    repeat {
        let suffix = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        candidate = directory.appendingPathComponent(suffix)
        index += 1
    } while FileManager.default.fileExists(atPath: candidate.path) && index < 1000
    return candidate
}
