import Darwin
import Foundation

/// A file another app opened with Apelin, copied into the app's own folder
/// and waiting for a conversation to attach it.
struct StagedSample: Equatable, Sendable {
    /// The copy under `Samples/Inbox/`; removed once it is attached.
    let url: URL
    /// The name it came with, cleaned for use as a file name.
    let name: String
}

/// Takes files another app hands over — Filza's share, Fila's, Files' Open in
/// — before a conversation reads them.
///
/// The URL an opener delivers is good only while the call lasts: Filza writes
/// a temporary export, Files lends a security-scoped provider. The bytes are
/// copied into `Samples/Inbox/<id>/` first, one folder per file, and the
/// conversation reads that. Nothing about the source is trusted: a folder or
/// a symbolic link is refused, and the name is cleaned, so the copy can add
/// nothing of its own to the path.
enum SampleInbox {
    /// The largest file copied. An attachment may not exceed 32 MB
    /// (`AgentSession.maximumAttachmentBytes`); this bound only keeps a share
    /// of something far bigger from filling the disk before that is found
    /// out. The source stays with its owner either way.
    static let maximumStagedBytes = 256 << 20

    enum Problem: LocalizedError, Equatable {
        case notAFile
        case tooLarge
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAFile:
                String(localized: "Apelin takes files, not folders.")
            case .tooLarge:
                String(localized: "Choose a regular file smaller than 32 MB.")
            case let .unreadable(reason):
                reason
            }
        }
    }

    /// Copies `url` under `root` and returns the copy. Its security scope is
    /// opened and closed here, on the thread that copies.
    static func stage(_ url: URL, in root: URL) throws -> StagedSample {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let source = try canonicalFile(at: url)
        let name = sanitizedName(url.lastPathComponent)
        let folder = root
            .appendingPathComponent("Samples", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(name, isDirectory: false)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
            return StagedSample(url: copy, name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw Problem.unreadable(error.localizedDescription)
        }
    }

    /// The file's canonical path, once it is proven to be a regular file:
    /// `lstat` refuses a folder or a symbolic link (the final component),
    /// then `realpath` resolves the levels above it, the way every other
    /// path decision does. The size bound is the file's own, so a link that
    /// grew after the check cannot slip past it.
    private static func canonicalFile(at url: URL) throws -> String {
        let path = url.path
        guard !path.utf8.contains(0) else {
            throw Problem.unreadable(String(cString: strerror(EINVAL)))
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw Problem.unreadable(String(cString: strerror(errno)))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw Problem.notAFile
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumStagedBytes) else {
            throw Problem.tooLarge
        }
        guard let resolved = realpath(path, nil) else {
            throw Problem.unreadable(String(cString: strerror(errno)))
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `name` as a copy may carry it: no path separators, no control
    /// characters, no leading dot that would hide it, and short enough for
    /// any file system. A name left empty becomes `Sample`.
    static func sanitizedName(_ name: String) -> String {
        var cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty {
            cleaned = "Sample"
        }
        if cleaned.count > 120 {
            cleaned = String(cleaned.prefix(120))
        }
        return cleaned
    }
}
