import ApelinProtocol
import Foundation
import KWWKAI

/// Which model a session talks to. Credentials are not part of this value:
/// they come from the session's `CredentialSource`, by kwwk store id.
public enum ProviderConfiguration: Sendable, Hashable, Codable {
    /// Anthropic's native Messages API with an API key
    /// (`anthropic-api-key`), or with an Anthropic OAuth sign-in
    /// (`anthropic`) when `oauth` is set.
    case anthropic(model: String, oauth: Bool = false)
    /// Any OpenAI-compatible Chat Completions endpoint. The base URL lives
    /// with the credential (kwwk's `baseUrl` extra) so an endpoint and its
    /// key cannot be mismatched.
    case openAICompatible(model: String)
    /// GitHub Copilot, through kwwk's Copilot provider: kwwk exchanges the
    /// stored GitHub token for a Copilot session token and routes each model
    /// to its wire format.
    case githubCopilot(model: String)
    /// Any other login kwwk stores, by its store id (`openai-codex`,
    /// `kimi-coding`, `google-api-key`, …), registered by kwwk's own
    /// `registerStored` exactly as the cases above are. A nil model is the
    /// provider's own default, kwwk's choice.
    case stored(storeID: String, model: String?)
    /// A model already registered on kwwk's `APIRegistry` (tests and
    /// in-process fakes). Needs no credential.
    case registered(Model)

    var storeID: String? {
        switch self {
        case let .anthropic(_, oauth):
            oauth ? CredentialProviderID.anthropicOAuth : CredentialProviderID.anthropicAPIKey
        case .openAICompatible: CredentialProviderID.openAICompatible
        case .githubCopilot: CredentialProviderID.githubCopilot
        case let .stored(storeID, _): storeID
        case .registered: nil
        }
    }

    var modelID: String? {
        switch self {
        case let .anthropic(model, _), let .openAICompatible(model), let .githubCopilot(model): model
        case let .stored(_, model): model
        case let .registered(model): model.id
        }
    }
}

public enum ProviderResolutionError: Error, Equatable, LocalizedError {
    /// No credential for this provider; the session waits for the app to
    /// deliver or sign in again. Nothing is read from the environment.
    case missingCredentials(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCredentials(id): "No saved sign-in for \(id). Sign in again in Apelin."
        }
    }
}

struct ResolvedProvider: Sendable {
    var model: Model
    var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    /// The stored sign-in it was resolved from; nil for one that needs none.
    var credentials: OAuthCredentials?
}

/// The account's Responses transport applies to every completion using it.
public enum ProviderTransport {
    public static func responses(model: Model, credentials: OAuthCredentials?) -> Transport? {
        guard model.api == "openai-responses" || model.api == "openai-codex-responses",
              case let .string(value)? = credentials?.extras[AgentSignInField.responsesTransport.rawValue],
              let selection = AgentResponsesTransport(rawValue: value)
        else { return nil }
        return Transport(rawValue: selection.rawValue)
    }
}

/// A selected effort is an explicit capability declared in the model settings.
enum ProviderReasoning {
    static func model(_ model: Model, level: ReasoningLevel?, explicitOff: Bool = false) -> Model {
        guard level != nil || explicitOff else { return model }
        var selected = model
        selected.reasoning = true
        var mapping = selected.thinkingLevelMap ?? [:]
        // Keep provider-specific wire values; custom levels use their own name.
        let key = level?.rawValue ?? "off"
        if (mapping[key] ?? nil) == nil {
            mapping[key] = level?.rawValue ?? "none"
        }
        selected.thinkingLevelMap = mapping
        if selected.api == "openai-completions" {
            var compat = selected.compat ?? ModelCompat()
            compat.supportsReasoningEffort = true
            selected.compat = compat
        }
        return selected
    }
}

enum ProviderResolver {
    /// Registers the provider on kwwk's registry from `credentials`, through
    /// kwwk's own stored-provider code, and returns the model to use.
    static func resolve(
        _ configuration: ProviderConfiguration,
        credentials: any CredentialSource,
    ) async throws -> ResolvedProvider {
        let stored = try await storedCredentials(configuration, in: credentials)
        guard let storeID = configuration.storeID else {
            if case let .registered(model) = configuration {
                return ResolvedProvider(model: model, authResolver: nil)
            }
            preconditionFailure("unreachable")
        }
        // OAuthManager(source:) keeps refreshed tokens in its own memory and
        // never writes them anywhere. Its refreshers are kwwk's own, with
        // Kimi's given an identity so that it never reaches for ~/.kwwk.
        let manager = OAuthManager(source: credentials, providers: KimiIdentity.refreshers())
        guard let resolved = try await registerStored(
            storeId: storeID,
            manager: manager,
            modelOverride: configuration.modelID,
        ) else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        return ResolvedProvider(model: resolved.model, authResolver: resolved.authResolver, credentials: stored)
    }

    /// The stored sign-in `configuration` needs, nil for one that needs
    /// none; missing, it is an error.
    static func storedCredentials(
        _ configuration: ProviderConfiguration,
        in credentials: any CredentialSource,
    ) async throws -> OAuthCredentials? {
        guard let storeID = configuration.storeID else { return nil }
        guard let stored = try await credentials.credentials(for: storeID) else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        return stored
    }
}
