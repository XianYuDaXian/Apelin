import ApelinCore
import Foundation

/// A project whose folder has gone from `Projects/` takes its conversations
/// with it; one still there keeps them, a temporary conversation has no
/// project to lose, and a `Projects/` that did not read takes nothing.
func checkDeletedProjects() {
    let weather = ChatSummary(title: "Rain", lastInteraction: Date(), projectName: "Weather")
    let weatherToo = ChatSummary(title: "Wind", lastInteraction: Date(), projectName: "Weather")
    let clock = ChatSummary(title: "Alarm", lastInteraction: Date(), projectName: "Clock")
    let general = ChatSummary(title: "Hello", lastInteraction: Date(), projectName: nil)
    let chats = [weather, clock, general, weatherToo]

    let gone = DeletedProjects.gone(from: chats, listed: ["Clock", ".Weather.creating-1a2b3c4d"])
    precondition(gone.projects == ["Weather"], "the project whose folder went: \(gone.projects)")
    precondition(gone.conversations == [weather.id, weatherToo.id], "and every conversation of it, none of another's or General Chat's")
    precondition(DeletedProjects.gone(from: chats, listed: ["Clock", "Weather"]) == DeletedProjects.Gone(), "every folder still there: nothing")
    precondition(DeletedProjects.gone(from: chats, listed: nil) == DeletedProjects.Gone(), "a listing that did not read takes nothing away")
    precondition(DeletedProjects.gone(from: [general], listed: []).conversations.isEmpty, "a temporary conversation has no project to lose")
    // The same name in another normalisation is the same folder.
    let café = ChatSummary(title: "Menu", lastInteraction: Date(), projectName: "Caf\u{E9}")
    precondition(DeletedProjects.gone(from: [café], listed: ["Cafe\u{301}"]).conversations.isEmpty, "a name is compared as text, not as bytes")

    // The listing, read where a project is deleted.
    let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("apelin-deleted-projects-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = DataFolder(home: home.path)
    try? FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
    precondition(DeletedProjects.listing(in: folder) == nil, "no Projects/ is no listing, so nothing goes")
    try? FileManager.default.createDirectory(at: folder.projects.appendingPathComponent("Clock"), withIntermediateDirectories: true)
    precondition(DeletedProjects.listing(in: folder) == ["Clock"], "the folders Projects/ holds")
    let elsewhere = home.appendingPathComponent("Elsewhere", isDirectory: true)
    try? FileManager.default.moveItem(at: folder.projects, to: elsewhere)
    try? FileManager.default.createSymbolicLink(at: folder.projects, withDestinationURL: elsewhere)
    precondition(DeletedProjects.listing(in: folder) == nil, "a Projects/ that links out of the data folder is no listing")
    print("ok: a deleted project's conversations go with it")
}
