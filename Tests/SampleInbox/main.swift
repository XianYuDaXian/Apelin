import Foundation

// Files another app opens with Apelin are copied into the data folder before
// a conversation reads them: a regular file byte for byte, a folder or a
// symbolic link refused, a name cleaned so the copy adds nothing of its own
// to the path.

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

func refuses(_ expected: SampleInbox.Problem, _ message: String, _ body: () throws -> Void) {
    do {
        try body()
        require(false, "\(message): nothing was refused")
    } catch let problem as SampleInbox.Problem {
        require(problem == expected, "\(message): got \(problem), expected \(expected)")
    } catch {
        require(false, "\(message): \(error)")
    }
}

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory.appendingPathComponent("apelin-sample-inbox-\(UUID().uuidString)")
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }

// A regular file is copied byte for byte into a folder of its own.
let source = root.appendingPathComponent("Sample.bin")
let bytes = Data((0 ..< 4096).map { UInt8($0 & 0xff) })
try bytes.write(to: source)
let staged = try SampleInbox.stage(source, in: root)
let stagedBytes = try Data(contentsOf: staged.url)
require(staged.name == "Sample.bin", "the name it came with is kept")
require(staged.url.lastPathComponent == "Sample.bin", "the copy carries that name")
require(stagedBytes == bytes, "the copy holds the same bytes")
require(staged.url.path.hasPrefix(root.appendingPathComponent("Samples/Inbox").path + "/"), "the copy is in the inbox")
require(fileManager.fileExists(atPath: source.path), "the source stays where it was")

// The same name staged twice gets two folders, and both copies survive.
let again = try SampleInbox.stage(source, in: root)
let againBytes = try Data(contentsOf: again.url)
require(again.url != staged.url, "a second copy gets a folder of its own")
require(againBytes == bytes, "and holds the same bytes")

// A folder and a symbolic link are refused.
let folder = root.appendingPathComponent("Folder")
try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
refuses(.notAFile, "a folder") { _ = try SampleInbox.stage(folder, in: root) }
let link = root.appendingPathComponent("Link")
try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
refuses(.notAFile, "a symbolic link") { _ = try SampleInbox.stage(link, in: root) }

// A file past the bound is refused before its bytes are copied.
let huge = root.appendingPathComponent("Huge.bin")
_ = fileManager.createFile(atPath: huge.path, contents: nil)
let handle = try FileHandle(forWritingTo: huge)
try handle.truncate(atOffset: UInt64(SampleInbox.maximumStagedBytes) + 1)
try handle.close()
refuses(.tooLarge, "a file past the bound") { _ = try SampleInbox.stage(huge, in: root) }

// A missing file is a failure, not a crash.
do {
    _ = try SampleInbox.stage(root.appendingPathComponent("Missing"), in: root)
    require(false, "a missing file must not be staged")
} catch is SampleInbox.Problem {}

// Names are cleaned for the copy and for the notice that names it.
require(SampleInbox.sanitizedName("a/b:c") == "a-b-c", "separators become dashes")
require(SampleInbox.sanitizedName(".hidden") == "hidden", "a leading dot goes")
require(SampleInbox.sanitizedName("...") == "Sample", "a name of dots becomes Sample")
require(SampleInbox.sanitizedName("  ") == "Sample", "a blank name becomes Sample")
require(SampleInbox.sanitizedName("a\u{0007}b") == "ab", "control characters go")
require(SampleInbox.sanitizedName("../../etc/passwd") == "etc-passwd", "a traversal adds no level")
require(SampleInbox.sanitizedName(String(repeating: "x", count: 300)).count == 120, "a long name is cut")

// Only the copies that succeeded are waiting.
let leftovers = try fileManager.contentsOfDirectory(
    at: root.appendingPathComponent("Samples/Inbox"),
    includingPropertiesForKeys: nil,
)
require(leftovers.count == 2, "two folders hold the two copies, got \(leftovers.count)")

print("ok: SampleInbox")
