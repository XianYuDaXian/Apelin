import ApelinProtocol
import Foundation

/// 用户自定义推理强度及其在候选列表中的位置。
enum CustomReasoningEfforts {
    static let positionChanged = Notification.Name("wiki.qaq.apelin.customReasoningEffortsChanged")

    private static let valuesKey = "agent.customReasoningEfforts"
    private static let positionKey = "agent.customReasoningPosition"
    static let positionFirst = "first"
    static let positionLast = "last"

    static var all: [AgentReasoningEffort] {
        let rawValues = UserDefaults.standard.stringArray(forKey: valuesKey) ?? []
        let values = rawValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(AgentReasoningEffort.init(rawValue:))
        return AgentReasoningEffort.ordered(values, customFirst: false)
            .filter { $0.isCustom }
    }

    static var position: String {
        UserDefaults.standard.string(forKey: positionKey) == positionFirst ? positionFirst : positionLast
    }

    /// 内置强度与自定义强度合并后的完整候选列表。
    static var options: [AgentReasoningEffort] {
        AgentReasoningEffort.ordered(
            AgentReasoningEffort.knownCases + all,
            customFirst: position == positionFirst,
        )
    }

    @discardableResult
    static func add(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = AgentReasoningEffort(rawValue: trimmed)
        guard !trimmed.isEmpty,
              trimmed.count <= 64,
              !trimmed.contains(where: \.isWhitespace),
              effort.isCustom,
              !all.contains(effort)
        else { return false }
        UserDefaults.standard.set(all.map { $0.rawValue } + [trimmed], forKey: valuesKey)
        notify()
        return true
    }

    @discardableResult
    static func remove(_ effort: AgentReasoningEffort) -> Bool {
        let updated = all.filter { $0 != effort }.map { $0.rawValue }
        guard updated.count != all.count else { return false }
        UserDefaults.standard.set(updated, forKey: valuesKey)
        notify()
        return true
    }

    static func setPosition(_ value: String) {
        UserDefaults.standard.set(value == positionFirst ? positionFirst : positionLast, forKey: positionKey)
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: positionChanged, object: nil)
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }
}
