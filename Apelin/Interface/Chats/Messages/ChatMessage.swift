import ApelinProtocol
import Foundation

/// A conversation row or an ordered entry in its summary's trace.
struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
        case thinking(seconds: Int?, tools: Int)
        case tool
        case approval(ApprovalDecision?)

        var isActivity: Bool {
            switch self {
            case .thinking, .tool: true
            default: false
            }
        }

        var isApproval: Bool {
            if case .approval = self {
                return true
            }
            return false
        }

        var needsApproval: Bool {
            if case .approval(nil) = self {
                return true
            }
            return false
        }

        var isThinking: Bool {
            if case .thinking(nil, _) = self {
                return true
            }
            return false
        }
    }

    let id: UUID
    var role: Role
    var text: String
    var detail = ""
    var trace: [ChatMessage] = []
    var attachments: [ComposerAttachment]
    /// A user message sent during a run that the run has not taken yet.
    var isQueued = false
    /// The conversation's last reply, with nothing running: it can be asked
    /// again (`agentRegenerate`).
    var canRetry = false
    /// A user message another conversation's agent sent: the line shown
    /// over the bubble naming that conversation.
    var sender: String?
    /// A tool row's call, and on a running summary its newest call, for the
    /// line under the summary.
    var banner: ToolCallBanner?
    /// A tool row whose result has not come back yet.
    var awaitsResult = false
    /// On a running summary, the calls in its trace still waiting for a result.
    var runningTools = 0
    /// On a running summary, the output tokens the run has received so far
    /// (the session's `received`); nil before the first count, and for a
    /// session older than the count.
    var receivedTokens: Int?
    /// An approval of a command that runs as root (`RootApprovalText`):
    /// the card says so, and Approve checks the device owner first.
    var runsAsRoot = false

    var activityTitle: String {
        guard case let .thinking(seconds, tools) = role else { return text }
        // An unfinished summary counts only the calls still running; between
        // them the model is at work again, so it reads "Thinking…".
        guard let seconds else {
            guard runningTools > 0 else { return String(localized: "Thinking…") }
            return runningTools == 1
                ? String(localized: "Executing 1 tool…")
                : String(localized: "Executing \(runningTools) tools…")
        }
        if seconds <= 0 {
            guard tools > 0 else { return "" }
            return tools == 1 ? String(localized: "Called 1 tool") : String(localized: "Called \(tools) tools")
        }
        if tools <= 0 {
            return seconds == 1
                ? String(localized: "Thought for 1 second")
                : String(localized: "Thought for \(seconds) seconds")
        }
        if seconds == 1 {
            return tools == 1
                ? String(localized: "Thought for 1 second and called 1 tool")
                : String(localized: "Thought for 1 second and called \(tools) tools")
        }
        return tools == 1
            ? String(localized: "Thought for \(seconds) seconds and called 1 tool")
            : String(localized: "Thought for \(seconds) seconds and called \(tools) tools")
    }

    var approvalTitle: String {
        text.components(separatedBy: "\n\n").first ?? ""
    }

    var approvalDetail: String {
        text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
    }

    init(id: UUID = UUID(), role: Role, text: String, attachments: [ComposerAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}
