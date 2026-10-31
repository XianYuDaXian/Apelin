import ApelinCore
import Foundation

/// A project whose folder has gone from `Projects/` takes its conversations
/// with it, as the app's own Delete takes them (`ChatRuntime.deleteProject`):
/// an agent deleted it with apelin_project_delete, after the host closed
/// its sessions, or a command or another app removed it. Nothing else
/// tells the app, so the folder is what it goes by.
enum DeletedProjects {
    struct Gone: Equatable {
        /// The projects whose folders went.
        var projects: Set<String> = []
        /// Their conversations, to take away.
        var conversations: [UUID] = []
    }

    /// The projects among `conversations`' that `listed`, the names
    /// `Projects/` holds now, no longer has, and their conversations. A
    /// listing that did not read (nil) takes nothing away, and a temporary
    /// conversation has no project to lose.
    static func gone(from conversations: [ChatSummary], listed: [String]?) -> Gone {
        guard let listed else { return Gone() }
        let present = Set(listed)
        let orphaned = conversations.filter { summary in
            summary.projectName.map { !present.contains($0) } ?? false
        }
        return Gone(projects: Set(orphaned.compactMap(\.projectName)), conversations: orphaned.map(\.id))
    }

    /// The names in `Projects/`, read where `DataFolder.removeProject`
    /// deletes: nil when the folder is missing, a link out of the data
    /// folder, or does not read.
    static func listing(in folder: DataFolder) -> [String]? {
        guard let root = CanonicalPath.resolve(folder.root.path),
              let projects = CanonicalPath.resolve(folder.projects.path), projects == root + "/Projects"
        else { return nil }
        return try? FileManager.default.contentsOfDirectory(atPath: projects)
    }
}
