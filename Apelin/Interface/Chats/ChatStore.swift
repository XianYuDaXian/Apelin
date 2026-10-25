import ApelinCore
import ApelinProtocol
import Foundation

struct ChatRecord: Codable, Sendable {
    var summary: ChatSummary
    var draft = ComposerDraft()
    var sessionID: String?
    var task: TaskHandle?
    /// Only ever appended to (`take`): the runtime's transcript of them reads
    /// on from the ones it has read (`ChatTranscriptCache`).
    var events: [TaskEvent] = []
    /// Messages sent and not yet echoed by the host, oldest first: shown at
    /// once, and kept on disk until their `prompt` or `queued` event comes
    /// back, so a kill mid-send loses none. Absent from older files.
    var sending: [ComposerDraft]?
    /// Set while the task of a reopened session replays the history
    /// `events` already hold (`reopen(as:)`). Absent from older files.
    var replay: SessionReplay?
}

/// The replay a reopened session's task starts with: every event of the
/// session again, renumbered and newly timed, before anything new. It ends
/// at the first user message or compaction the conversation has not seen:
/// Compact… reopens a stopped session too, with no message after it.
struct SessionReplay: Codable, Sendable {
    private static let userMessageKinds: Set<String> = ["prompt", "steer"]
    private static let compactionKind = "compactionStarted"
    /// A reply asked again is new even though no user message follows it.
    private static let retryKind = "regenerated"

    /// How far the task has been read.
    var cursor = EventSeq.start
    /// The user messages still to come again: those with an id, and how many
    /// without one (a steer, or a message another conversation sent).
    private var messageIDs: Set<UUID> = []
    private var unnamedMessages = 0
    /// The compactions still to come again. Absent from older files, which
    /// have none.
    private var compactions: Int?
    /// The retries still to come again. Absent from older files.
    private var retries: Int?

    /// The replay of a session whose history is `events`.
    init(of events: [TaskEvent]) {
        for event in events where Self.userMessageKinds.contains(event.kind) {
            if let id = ChatTranscript.userMessageID(of: event) {
                messageIDs.insert(id)
            } else {
                unnamedMessages += 1
            }
        }
        compactions = events.count { $0.kind == Self.compactionKind }
        retries = events.count { $0.kind == Self.retryKind }
    }

    /// Whether `event` is still part of the replay, counting off the user
    /// message it repeats.
    mutating func replays(_ event: TaskEvent) -> Bool {
        if event.kind == Self.retryKind {
            // A retry has no user message after it: this is what ends the
            // replay when the conversation asked for its last reply again.
            guard let remaining = retries, remaining > 0 else { return false }
            retries = remaining - 1
            return true
        }
        if event.kind == Self.compactionKind {
            guard let remaining = compactions, remaining > 0 else { return false }
            compactions = remaining - 1
            return true
        }
        guard Self.userMessageKinds.contains(event.kind) else { return true }
        if let id = ChatTranscript.userMessageID(of: event) {
            return messageIDs.remove(id) != nil
        }
        guard unnamedMessages > 0 else { return false }
        unnamedMessages -= 1
        return true
    }
}

extension ChatRecord {
    /// Takes out of `sending` each message `events` echo, and returns it
    /// with the event that echoed it. A draft put back by
    /// `reclaimUnsent` that the host did take is emptied too, unless its
    /// text was changed since.
    mutating func takeEchoed(by events: [TaskEvent]) -> [(draft: ComposerDraft, event: TaskEvent)] {
        var echoed: [(draft: ComposerDraft, event: TaskEvent)] = []
        for event in events {
            guard let id = ChatTranscript.userMessageID(of: event) else { continue }
            if let index = sending?.firstIndex(where: { $0.id == id }), let draft = sending?.remove(at: index) {
                echoed.append((draft, event))
            }
            if draft.id == id, draft.text == event.payload?["text"]?.stringValue ?? "" {
                draft = ComposerDraft()
            }
        }
        if sending?.isEmpty == true {
            sending = nil
        }
        return echoed
    }

    /// A send that failed: the message leaves `sending`, and its draft
    /// returns if nothing was typed since and the host did not record it
    /// before failing (its event shows it then). Returns whether it did.
    mutating func takeBack(_ message: ComposerDraft) -> Bool {
        sending?.removeAll { $0.id == message.id }
        if sending?.isEmpty == true {
            sending = nil
        }
        let recorded = events.contains { ChatTranscript.userMessageID(of: $0) == message.id }
        guard !recorded, draft.text.isEmpty, draft.attachments.isEmpty else { return false }
        draft = message
        return true
    }

    /// The session is now `task`. One that is not the task `events` came
    /// from belongs to a reopened session, and starts by replaying the whole
    /// history under its own numbering; `events` already hold it, so `take`
    /// reads past that replay instead of showing it again. With no history
    /// there is nothing to read past: a first task's events are all new,
    /// an error before its first prompt included.
    mutating func reopen(as task: TaskHandle) {
        guard self.task != task else { return }
        self.task = task
        replay = events.isEmpty ? nil : SessionReplay(of: events)
    }

    /// Where reading the session's task goes on from.
    var cursor: EventSeq {
        replay?.cursor ?? events.last?.seq ?? .start
    }

    /// Adds the events of `batch` past the cursor, less a reopened task's
    /// replay, and returns them.
    mutating func take(_ batch: [TaskEvent]) -> [TaskEvent] {
        let fresh = batch.filter { $0.seq > cursor }
        guard var replay else {
            events += fresh
            return fresh
        }
        for (index, event) in fresh.enumerated() {
            guard replay.replays(event) else {
                self.replay = nil
                let taken = Array(fresh[index...])
                events += taken
                return taken
            }
            replay.cursor = event.seq
        }
        self.replay = replay
        return []
    }

    /// After a relaunch, what is still in `sending` may never have reached
    /// the host, so it goes back to the draft, before anything typed after
    /// it. A lone message keeps its id: if the host did take it, sending it
    /// again is not a second message, and its echo empties the draft.
    mutating func reclaimUnsent() {
        _ = takeEchoed(by: events)
        guard let unsent = sending else { return }
        sending = nil
        let parts = (unsent + [draft]).filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
        if parts.count == 1, let only = parts.first {
            draft = only
        } else {
            draft = ComposerDraft(text: parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                  attachments: parts.flatMap(\.attachments))
        }
    }
}

/// Serial disk writes keep a slow earlier save from replacing a newer transcript.
actor ChatStore {
    private let folder: DataFolder
    private var revisions: [UUID: Int] = [:]

    init(folder: DataFolder) {
        self.folder = folder
    }

    func load() throws -> [ChatRecord] {
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        guard let directoryPath = CanonicalPath.resolve(directory.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let path = CanonicalPath.resolve(url.path),
                      CanonicalPath.isCanonical(path, inside: directoryPath)
                else { return nil }
                return try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            }
    }

    func save(_ record: ChatRecord, revision: Int) throws {
        let id = record.summary.id
        guard revision > (revisions[id] ?? -1) else { return }
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent(id.uuidString + ".json"),
            options: .atomic,
        )
        revisions[id] = revision
    }

    func remove(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(
                at: folder.root.appendingPathComponent("Chats/" + id.uuidString + ".json"),
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Deleting before the first queued save is also a successful delete.
        }
        revisions[id] = Int.max
    }
}
