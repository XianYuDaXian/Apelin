@testable import ApelinAgent
import Foundation
import KWWKAI
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
}

/// A Responses-only endpoint that records every request, including a stray upgrade.
private final class ResponsesHTTPServer: @unchecked Sendable {
    let listener: NWListener
    private let ports: AsyncStream<UInt16>
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []

    var requests: [[String: Any]] { lock.withLock { recorded } }

    init() throws {
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
            lock.withLock { recorded.append(payload) }
            #expect(payload["stream"] as? Bool == true)
            let body = """
            data: {"type":"response.created","response":{"id":"reply","status":"in_progress"}}

            data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","content":[]}}

            data: {"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}

            data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"OK"}

            data: {"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"OK"}}

            data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message"}}

            data: {"type":"response.completed","response":{"id":"reply","status":"completed","usage":{"input_tokens":2,"output_tokens":1}}}


            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
