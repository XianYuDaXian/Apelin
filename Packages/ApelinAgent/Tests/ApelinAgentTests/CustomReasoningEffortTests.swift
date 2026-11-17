@testable import ApelinAgent
import KWWKAI
import Testing

@Suite("Custom reasoning efforts")
struct CustomReasoningEffortTests {
    @Test
    func customRawValueRidesOnKnownCarrierLevel() {
        let model = Model(
            id: "custom-reasoner",
            api: "openai-completions",
            provider: "test",
            reasoning: true,
        )

        let selected = ProviderReasoning.model(
            model,
            level: .high,
            reasoningEffortRaw: "Ultra-High",
        )

        #expect(selected.thinkingLevelMap?["high"] == "Ultra-High")
    }

    @Test
    func builtInRawValueKeepsNormalMapping() {
        let model = Model(
            id: "built-in-reasoner",
            api: "openai-completions",
            provider: "test",
            reasoning: true,
        )

        let selected = ProviderReasoning.model(
            model,
            level: .high,
            reasoningEffortRaw: "high",
        )

        #expect(selected.thinkingLevelMap?["high"] == "high")
    }
}
