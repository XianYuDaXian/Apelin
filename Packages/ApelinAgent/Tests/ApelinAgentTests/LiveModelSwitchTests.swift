@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// The model a switch made mid-turn lands on: the answer in flight finishes
/// with the model it started with, and the turn's next request goes to the
/// new one without the turn being interrupted.
@Suite("Live model switch")
struct LiveModelSwitchTests {
    @Test(.timeLimit(.minutes(1)))
    func `a switch made while an answer streams lands at the next request of the same turn`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let original = await registerFauxProvider()
        let selected = await registerFauxProvider()
        defer { original.unregister(); selected.unregister() }
        try home.write("README.md", "The readme.\n")
        let gate = TurnGate()
        let asked = AskedModels()
        original.setResponses([.factory { _, _, _, model in
            await asked.add(model.api)
            // Hold the first request open so the switch happens mid-turn.
            await gate.arriveAndWait()
            return fauxAssistantMessage(blocks: [
                fauxToolCall(name: "file_read", arguments: ["reason": "Read the readme", "path": "README.md"]),
            ], stopReason: .toolUse)
        }])
        selected.setResponses([.factory { _, _, _, model in
            await asked.add(model.api)
            return fauxAssistantMessage("Done.")
        }])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(original.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Read the readme", messageID: UUID())
        await gate.waitForArrival()
        try await session.switchModel(
            provider: .registered(selected.getModel()),
            thinking: .off,
            credentials: DeliveredCredentialSource(),
        )
        await gate.release()
        await session.waitForIdle()
        #expect(await asked.all == [original.api, selected.api])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a switch made at rest is the model the next turn starts with`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let original = await registerFauxProvider()
        let selected = await registerFauxProvider()
        defer { original.unregister(); selected.unregister() }
        let asked = AskedModels()
        original.setResponses([.factory { _, _, _, model in
            await asked.add(model.api)
            return fauxAssistantMessage("First.")
        }])
        selected.setResponses([.factory { _, _, _, model in
            await asked.add(model.api)
            return fauxAssistantMessage("Second.")
        }])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(original.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("One", messageID: UUID())
        await session.waitForIdle()
        try await session.switchModel(
            provider: .registered(selected.getModel()),
            thinking: .off,
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Two", messageID: UUID())
        await session.waitForIdle()
        #expect(await asked.all == [original.api, selected.api])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a model's context window reaches every request and caps output tokens`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let seen = SeenContextWindows()
        faux.setResponses([.factory { _, _, _, model in
            await seen.add((model.contextWindow, model.maxTokens))
            return fauxAssistantMessage("Done.")
        }, .factory { _, _, _, model in
            await seen.add((model.contextWindow, model.maxTokens))
            return fauxAssistantMessage("Again.")
        }, .factory { _, _, _, model in
            await seen.add((model.contextWindow, model.maxTokens))
            return fauxAssistantMessage("Configured.")
        }])
        var model = faux.getModel()
        model.contextWindow = 256_000
        model.maxTokens = 100_000
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(model), approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot, contextWindow: 64_000,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("One", messageID: UUID())
        await session.waitForIdle()
        try await session.switchModel(
            provider: .registered(model), thinking: .off, contextWindow: 96_000,
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Two", messageID: UUID())
        await session.waitForIdle()
        try await session.configure(
            provider: .registered(model), thinking: .off, contextWindow: 128_000,
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Three", messageID: UUID())
        await session.waitForIdle()
        let windows = await seen.all
        #expect(windows.count == 3)
        #expect(windows[0].0 == 64_000 && windows[0].1 == 64_000, "output is capped to a smaller window")
        #expect(windows[1].0 == 96_000 && windows[1].1 == 96_000)
        #expect(windows[2].0 == 128_000 && windows[2].1 == 100_000, "a larger window leaves the model's output cap")
        #expect(ProviderModelWindow.apply(0, to: model) == model)
        #expect(ProviderModelWindow.apply(10_000_001, to: model) == model)
        var omittedOutput = model
        omittedOutput.maxTokens = 0
        #expect(ProviderModelWindow.apply(4096, to: omittedOutput).maxTokens == 0, "kwwk's 0 omits the field")
        await session.close()
    }
}

/// One request's arrival, and the test's release of it.
private actor TurnGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        for waiter in arrivals { waiter.resume() }
        arrivals = []
        guard !released else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        for waiter in releases { waiter.resume() }
        releases = []
    }
}

private actor SeenContextWindows {
    private(set) var all: [(Int?, Int)] = []

    func add(_ seen: (Int?, Int)) {
        all.append(seen)
    }
}

private actor AskedModels {
    private(set) var all: [String] = []

    func add(_ id: String) {
        all.append(id)
    }
}
