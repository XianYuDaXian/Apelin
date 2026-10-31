import Foundation

/// One launch's journal: the file Dog opens at launch in the data folder's
/// `Journal/`, named `Dog_<yyyy-MM-dd_HH-mm-ss>_<eight characters>.log`.
struct JournalFile: Hashable, Sendable {
    let url: URL
    /// When the launch began, read off the name; nil for a name Dog did
    /// not write.
    let started: Date?
    let size: Int

    var name: String {
        url.lastPathComponent
    }
}

/// The journals Dog keeps, one per launch, its 100 newest: the only record
/// of an earlier launch, since the live log keeps no history on iOS.
enum JournalFiles {
    /// Dog's journals in `directory`, newest first: by the launch in the
    /// name, then by name, with names Dog did not date last. Only regular
    /// files named `Dog_` … `.log` count, as Dog's own clean-up counts them;
    /// a link is not followed.
    static func list(in directory: URL) -> [JournalFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasPrefix("Dog_") && $0.hasSuffix(".log") }.compactMap { name -> JournalFile? in
            let url = directory.appendingPathComponent(name)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
            return JournalFile(url: url, started: started(fromName: name), size: Int(metadata.st_size))
        }
        return files.sorted { a, b in
            switch (a.started, b.started) {
            case let (first?, second?) where first != second: first > second
            case (_?, nil): true
            case (nil, _?): false
            default: a.name > b.name
            }
        }
    }

    /// The launch a name Dog wrote begins with: `Dog_`, the date in local
    /// time, `_`, eight characters and `.log`.
    static func started(fromName name: String) -> Date? {
        guard name.count == 36, name.hasPrefix("Dog_"), name.hasSuffix(".log") else { return nil }
        return formatter.date(from: String(name.dropFirst(4).prefix(19)))
    }

    /// Dog's own: fixed to en_US_POSIX and the Gregorian calendar, so the
    /// reader's calendar or clock cannot change how a name reads back.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
