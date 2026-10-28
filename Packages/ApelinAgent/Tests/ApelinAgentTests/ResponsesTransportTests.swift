@testable import ApelinAgent
import Foundation
import KWWKAI
import KWWKAgent
import Network
import Testing

@Suite("Responses HTTP transport", .timeLimit(.minutes(1)))
struct ResponsesTransportTests {
    @Test
    func `HTTP selection survives prompts retries configuration changes and model switches`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let server = try ResponsesHTTPServer()
        defer { server.listener.cancel() }
        let port = try await server.port()
        let credentials = DeliveredCredentialSource(["openai-api-key": OAuthCredentials(
            access: "candidate-secret", refresh: "", expires: .max,
            extras: ["baseUrl": .string("http://127.0.0.1:\(port)/v1"), "responsesTransport": .string("sse")],
        )])
        let first = ProviderConfiguration.stored(storeID: "openai-api-key", model: "first-model")
        let second = ProviderConfiguration.stored(storeID: "openai-api-key", model: "second-model")
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: first, approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: credentials,
        )
        try await session.prompt("First", messageID: UUID())
        await session.waitForIdle()
        try await session.regenerate()
        await session.waitForIdle()
        try await session.configure(provider: second, thinking: .off, credentials: credentials)
        try await session.prompt("Second", messageID: UUID())
        await session.waitForIdle()
        try await session.switchModel(provider: first, thinking: .off, credentials: credentials)
        try await session.prompt("Third", messageID: UUID())
        await session.waitForIdle()
        let models = server.requests.map { $0["model"] as? String }
        #expect(models == ["first-model", "first-model", "second-model", "first-model"])
        let transcript = try await session.log.readTranscript()
        let answers = transcript.compactMap { message -> String? in
            guard case let .assistant(assistant) = message else { return nil }
            return assistant.content.compactMap { block -> String? in
                if case let .text(text) = block { return text.text }
                return nil
            }.joined()
        }
        #expect(answers == ["OK", "OK", "OK"])
        await session.generateTitle(for: "A title")
        await session.waitForTitle()
        #expect(server.requests.count == 5)
        let records = try await session.log.records(afterSeq: 0)
        #expect(records.contains { if case .titleUpdated("OK") = $0.event { return true }; return false })
        await session.close()
    }

    @Test
    func `switching to a Responses HTTP account mid-turn uses HTTP at the next request`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("README.md", "Readme")
        let server = try ResponsesHTTPServer()
        defer { server.listener.cancel() }
        let port = try await server.port()
        let credentials = DeliveredCredentialSource(["openai-api-key": OAuthCredentials(
            access: "candidate-secret", refresh: "", expires: .max,
            extras: ["baseUrl": .string("http://127.0.0.1:\(port)/v1"), "responsesTransport": .string("sse")],
        )])
        let original = await registerFauxProvider()
        defer { original.unregister() }
        let (arrivals, arrived) = AsyncStream<Void>.makeStream()
        let (releases, release) = AsyncStream<Void>.makeStream()
        original.setResponses([.factory { _, _, _, _ in
            arrived.yield()
            for await _ in releases { break }
            return fauxAssistantMessage(blocks: [
                fauxToolCall(name: "file_read", arguments: ["reason": "Read the readme", "path": "README.md"]),
            ], stopReason: .toolUse)
        }])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(original.getModel()),
                approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: credentials,
        )
        try await session.prompt("Read the readme", messageID: UUID())
        for await _ in arrivals { break }
        try await session.switchModel(
            provider: .stored(storeID: "openai-api-key", model: "switched-model"),
            thinking: .off, credentials: credentials,
        )
        release.yield()
        await session.waitForIdle()
        #expect(server.requests.map { $0["model"] as? String } == ["switched-model"])
        await session.close()
    }

    @Test
    func `selected efforts preserve provider wire aliases and enable declared custom capabilities`() {
        let catalog = Model(
            id: "mapped-reasoner", api: "openai-responses", provider: "test",
            reasoning: true, thinkingLevelMap: ["xhigh": "max", "off": nil],
        )
        let mapped = ProviderReasoning.model(catalog, level: .xhigh)
        #expect(resolveThinkingLevel(mapped, .xhigh) == "max")
        #expect(mapped.thinkingLevelMap == catalog.thinkingLevelMap)
        let disabled = ProviderReasoning.model(catalog, level: nil, explicitOff: true)
        #expect(disabled.thinkingLevelMap?["off"] == "none")
        #expect(ProviderReasoning.model(catalog, level: nil) == catalog)
        let custom = Model(id: "custom", api: "openai-completions", provider: "test")
        let selected = ProviderReasoning.model(custom, level: .max)
        #expect(selected.reasoning)
        #expect(selected.compat?.supportsReasoningEffort == true)
        #expect(resolveThinkingLevel(selected, .max) == "max")
        #expect(ProviderReasoning.model(custom, level: nil) == custom)
    }

    @Test
    func `custom Responses models send every selected reasoning effort without clamping`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let server = try ResponsesHTTPServer()
        defer { server.listener.cancel() }
        let port = try await server.port()
        let credentials = Self.credentials(port: port)
        let provider = ProviderConfiguration.stored(storeID: "openai-api-key", model: "custom-reasoner")
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: provider, approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: credentials,
        )
        let otherManager = OAuthManager(source: DeliveredCredentialSource(["openai-api-key": OAuthCredentials(
            access: "unrelated-secret", refresh: "", expires: .max,
        )]))
        _ = try await registerStored(storeId: "openai-api-key", manager: otherManager, modelOverride: "other-model")
        let levels: [ThinkingLevel] = [.minimal, .low, .medium, .high, .xhigh, .max, .off]
        for level in levels {
            try await session.configure(provider: provider, thinking: level, credentials: credentials)
            try await session.prompt("Use the chosen effort", messageID: UUID())
            await session.waitForIdle()
        }
        let efforts = server.requests.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String }
        #expect(efforts == ["minimal", "low", "medium", "high", "xhigh", "max", "none"])
        let catalogID = ProviderConfiguration.stored(storeID: "openai-api-key", model: "gpt-5")
        try await session.configure(provider: catalogID, thinking: .off, explicitReasoningOff: true, credentials: credentials)
        try await session.prompt("Explicitly disable reasoning", messageID: UUID())
        await session.waitForIdle()
        #expect((server.requests.last?["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        try await session.configure(provider: catalogID, thinking: .off, credentials: credentials)
        try await session.prompt("Use the catalog default", messageID: UUID())
        await session.waitForIdle()
        #expect(server.requests.last?["reasoning"] == nil)
        await session.close()
    }

    @Test
    func `effort changes during an HTTP response apply after its tool call on the same model`() async throws {
        let changes: [(ThinkingLevel, ThinkingLevel)] = [(.off, .xhigh), (.low, .max), (.high, .off)]
        for (initial, next) in changes {
            let home = try TemporaryHome()
            defer { home.remove() }
            try home.write("README.md", "Readme")
            let (arrivals, arrived) = AsyncStream<Void>.makeStream()
            let (releases, release) = AsyncStream<Void>.makeStream()
            let server = try ResponsesHTTPServer(firstToolResponse: true) {
                arrived.yield()
                for await _ in releases { break }
            }
            defer { server.listener.cancel() }
            let port = try await server.port()
            let credentials = Self.credentials(port: port)
            let provider = ProviderConfiguration.stored(storeID: "openai-api-key", model: "custom-reasoner")
            let session = try await AgentSession(
                configuration: AgentSessionConfiguration(
                    project: home.project, provider: provider, approval: ApprovalPolicy(mode: .relaxed),
                    dataRoot: home.dataRoot, thinking: initial, explicitReasoningOff: initial == .off,
                ),
                backend: MockBackend(), digests: MockDigestLedger(), credentials: credentials,
            )
            try await session.prompt("Read the readme", messageID: UUID())
            for await _ in arrivals { break }
            try await session.switchModel(
                provider: provider, thinking: next, explicitReasoningOff: next == .off, credentials: credentials,
            )
            #expect(server.requests.count == 1)
            release.yield()
            await session.waitForIdle()
            let requests = server.requests
            #expect(requests.count == 2)
            let efforts = requests.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String }
            #expect(efforts == [initial == .off ? "none" : initial.rawValue, next == .off ? "none" : next.rawValue])
            #expect(requests.allSatisfy { $0["model"] as? String == "custom-reasoner" })
            let inputs = requests.last?["input"] as? [[String: Any]] ?? []
            #expect(inputs.contains { $0["type"] as? String == "function_call_output" })
            let transcript = try await session.log.readTranscript()
            #expect(transcript.contains { message in
                guard case let .assistant(assistant) = message else { return false }
                return assistant.content.contains { if case let .text(text) = $0 { return text.text == "OK" }; return false }
            })
            await session.close()
        }
    }

    private static func credentials(port: UInt16) -> DeliveredCredentialSource {
        DeliveredCredentialSource(["openai-api-key": OAuthCredentials(
            access: "candidate-secret", refresh: "", expires: .max,
            extras: ["baseUrl": .string("http://127.0.0.1:\(port)/v1"), "responsesTransport": .string("sse")],
        )])
    }
}

/// A Responses-only endpoint that records every request, including a stray upgrade.
private final class ResponsesHTTPServer: @unchecked Sendable {
    let listener: NWListener
    private let ports: AsyncStream<UInt16>
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []

    var requests: [[String: Any]] { lock.withLock { recorded } }

    private let firstToolResponse: Bool
    private let beforeFirstResponse: (@Sendable () async -> Void)?

    init(firstToolResponse: Bool = false, beforeFirstResponse: (@Sendable () async -> Void)? = nil) throws {
        self.firstToolResponse = firstToolResponse
        self.beforeFirstResponse = beforeFirstResponse
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let (ports, ready) = AsyncStream<UInt16>.makeStream()
        self.ports = ports
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port { ready.yield(port.rawValue) }
                ready.finish()
            case .waiting, .failed, .cancelled: ready.finish()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue(label: "responses-http-connection"))
            self?.respond(connection)
        }
        listener.start(queue: DispatchQueue(label: "responses-http-listener"))
    }

    func port() async throws -> UInt16 {
        var iterator = ports.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func respond(_ connection: NWConnection, received: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, ended, error in
            let request = received + (data ?? Data())
            guard let separator = request.range(of: Data("\r\n\r\n".utf8)) else {
                if ended || error != nil { connection.cancel(); return }
                respond(connection, received: request)
                return
            }
            let header = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.count - separator.upperBound >= length else {
                if ended || error != nil { connection.cancel(); return }
                respond(connection, received: request)
                return
            }
            #expect(header.hasPrefix("POST /v1/responses HTTP/1.1"))
            #expect(!header.lowercased().contains("upgrade: websocket"))
            #expect(header.lowercased().contains("authorization: bearer candidate-secret"))
            let payload = (try? JSONSerialization.jsonObject(with: Data(request[separator.upperBound...]))) as? [String: Any] ?? [:]
            let first = lock.withLock {
                recorded.append(payload)
                return recorded.count == 1
            }
            #expect(payload["stream"] as? Bool == true)
            let textBody = """
            data: {"type":"response.created","response":{"id":"reply","status":"in_progress"}}

            data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","content":[]}}

            data: {"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}

            data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"OK"}

            data: {"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"OK"}}

            data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message"}}

            data: {"type":"response.completed","response":{"id":"reply","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}


            """
            let toolBody = """
            data: {"type":"response.created","response":{"id":"tool-reply","status":"in_progress"}}

            data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_read","call_id":"call_read","name":"file_read","arguments":""}}

            data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\\"reason\\\":\\\"Read the readme\\\",\\\"path\\\":\\\"README.md\\\"}"}

            data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_read","call_id":"call_read","name":"file_read","arguments":"{\\\"reason\\\":\\\"Read the readme\\\",\\\"path\\\":\\\"README.md\\\"}"}}

            data: {"type":"response.completed","response":{"id":"tool-reply","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}


            """
            let body = first && firstToolResponse ? toolBody : textBody
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            Task {
                if first { await beforeFirstResponse?() }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
