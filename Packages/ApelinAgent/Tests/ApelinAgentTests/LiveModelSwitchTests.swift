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

private actor AskedModels {
    private(set) var all: [String] = []

    func add(_ id: String) {
        all.append(id)
    }
}
