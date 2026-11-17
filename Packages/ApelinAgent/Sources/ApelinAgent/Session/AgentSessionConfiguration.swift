import ApelinProtocol
import struct ApelinToolCore.ToolManifestPolicy
import Foundation
import KWWKAgent
import KWWKAI

/// How a session is opened. The host fills it from the app's settings and
/// the project record; the agent cannot change any of it.
public struct AgentSessionConfiguration: Sendable {
    /// A UUID string; also the session folder's name.
    public var id: String
    public var project: ProjectIdentity
    public var temporaryID: String?
    public var provider: ProviderConfiguration
    public var approval: ApprovalPolicy
    public var dataRoot: ApelinDataRoot
    public var mcpServers: [MCPServerConfiguration]
    public var thinking: ThinkingLevel
    /// 用户自选的非标准推理强度原始值；内置值时为 nil。
    public var reasoningEffortRaw: String?
    /// The reader explicitly chose Off in a model capability override.
    public var explicitReasoningOff: Bool
    /// The model's context window from model settings; nil uses its catalog
    /// or provider default.
    public var contextWindow: Int?
    /// The processing tier its requests ask for; nil is the provider's default.
    public var serviceTier: ServiceTier?
    /// Hard cap on assistant turns per run; nil for none.
    public var maxTurns: Int?
    /// The install root the session host derived from its own path, which
    /// the system prompt names with the bootstrap; nil where there is none
    /// (the Mac tests).
    public var installRoot: String?
    /// The device's language and clock, which each message's
    /// `<system-state>` names.
    public var systemState: SystemStateSource
    /// Whether the device has a route, which a model request the network
    /// failed waits for (`NetworkRecovery`).
    public var network: NetworkPath
    /// The session host started since this conversation last ran, as the
    /// host decides (`AgentOpenRequest.hostRestarted`): when it has history,
    /// the next message's `<system-state>` says its paths may be stale.
    public var hostRestarted: Bool
    /// Whom the agent tool extensions under the install root must belong
    /// to for their tools to be offered: root, as the package manager
    /// installs them and the host requires; the tests' own user.
    public var toolExtensionPolicy: ToolManifestPolicy

    public init(
        id: String = UUID().uuidString,
        project: ProjectIdentity,
        temporaryID: String? = nil,
        provider: ProviderConfiguration,
        approval: ApprovalPolicy,
        dataRoot: ApelinDataRoot = .current,
        mcpServers: [MCPServerConfiguration] = [],
        thinking: ThinkingLevel = .off,
        reasoningEffortRaw: String? = nil,
        explicitReasoningOff: Bool = false,
        contextWindow: Int? = nil,
        serviceTier: ServiceTier? = nil,
        maxTurns: Int? = nil,
        installRoot: String? = nil,
        systemState: SystemStateSource = .device,
        network: NetworkPath = .system,
        hostRestarted: Bool = false,
        toolExtensionPolicy: ToolManifestPolicy = ToolManifestPolicy(),
    ) {
        self.id = id
        self.project = project
        self.temporaryID = temporaryID
        self.provider = provider
        self.approval = approval
        self.dataRoot = dataRoot
        self.mcpServers = mcpServers
        self.thinking = thinking
        self.reasoningEffortRaw = reasoningEffortRaw
        self.explicitReasoningOff = explicitReasoningOff
        self.contextWindow = contextWindow
        self.serviceTier = serviceTier
        self.maxTurns = maxTurns
        self.installRoot = installRoot
        self.systemState = systemState
        self.network = network
        self.hostRestarted = hostRestarted
        self.toolExtensionPolicy = toolExtensionPolicy
    }
}

/// 把协议层的推理强度转换成 kwwk 的已知级别；自定义值使用 high 作为载体，
/// 真正的原始值由 Model.thinkingLevelMap 透传。
public enum AgentReasoningSelection {
    public static func thinkingLevel(for effort: AgentReasoningEffort?) -> ThinkingLevel {
        guard let effort else { return .off }
        if let known = ThinkingLevel(rawValue: effort.rawValue) {
            return known
        }
        return .high
    }
}
