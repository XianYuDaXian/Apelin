import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
enum EnabledModels {
    private static func key(_ provider: AgentProvider) -> String {
        "enabledModels.\(provider.rawValue)"
    }

    static func ids(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(provider)) ?? [])
    }

    static func save(
        _ models: Set<String>,
        custom: Set<String>,
        hidden: Set<String>,
        reasoningEfforts: [String: [AgentReasoningEffort]],
        for provider: AgentProvider,
    ) {
        UserDefaults.standard.set(models.sorted(), forKey: key(provider))
        UserDefaults.standard.set(custom.sorted(), forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.set(hidden.sorted(), forKey: "hiddenModels.\(provider.rawValue)")
        UserDefaults.standard.set(
            reasoningEfforts.mapValues { efforts in
                AgentReasoningEffort.allCases.filter { efforts.contains($0) }.map(\.rawValue)
            },
            forKey: "modelReasoningEfforts.\(provider.rawValue)",
        )
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for provider: AgentProvider) {
        UserDefaults.standard.removeObject(forKey: key(provider))
        UserDefaults.standard.removeObject(forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.removeObject(forKey: "hiddenModels.\(provider.rawValue)")
        UserDefaults.standard.removeObject(forKey: "modelReasoningEfforts.\(provider.rawValue)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func customIDs(for provider: AgentProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "customModels.\(provider.rawValue)") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenModels.\(provider.rawValue)") ?? [])
    }

    static func reasoningEffortOverrides(for provider: AgentProvider) -> [String: [AgentReasoningEffort]] {
        let stored = UserDefaults.standard.dictionary(forKey: "modelReasoningEfforts.\(provider.rawValue)") ?? [:]
        return stored.compactMapValues { value in
            guard let values = value as? [String] else { return nil }
            return AgentReasoningEffort.allCases.filter { values.contains($0.rawValue) }
        }
    }

    static func reasoningEfforts(for model: String, in account: AgentAccount) -> [AgentReasoningEffort] {
        if account.isAPIKeyAccount, let override = reasoningEffortOverrides(for: account.provider)[model] {
            return override
        }
        return account.reasoningEfforts?[model] ?? []
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            if account.isAPIKeyAccount {
                enabled.reasoningEfforts = (account.reasoningEfforts ?? [:]).merging(
                    reasoningEffortOverrides(for: account.provider),
                    uniquingKeysWith: { _, override in override },
                )
            }
            let ids = ids(for: account.provider).subtracting(hiddenIDs(for: account.provider))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
