//
//  AgentModelClient.swift
//  leanring-buddy
//
//  The agent loop's one way to reach a model: TeachyAIRouter, job `.agent`.
//  Streams by default (read through StreamIdleGuard, and closed as soon as the
//  reply is complete, because some tiers never close their stream); falls back
//  to a plain call if a stream fails or comes back empty.
//

import Foundation

@MainActor
enum AgentModelClient {
    static func body(for request: AgentModelRequest) -> [String: Any] {
        var body: [String: Any] = [
            "max_tokens": 4096,
            "messages": request.messages
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = request.parallelToolCalls
        }
        if request.streams { body["stream"] = true }
        return body
    }

    static func hasImages(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { ($0["type"] as? String) == "image_url" }
        }
    }

    static func send(_ request: AgentModelRequest) async throws -> AgentAssistantTurn {
        let hasImages = hasImages(request.messages)
        if request.streams {
            do {
                let turn = try await sendStreaming(request, hasImages: hasImages)
                if !turn.content.isEmpty || !turn.toolCalls.isEmpty { return turn }
                // An empty stream (a tier that answered with nothing): ask once more the plain way.
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TeachyAIBillingError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                print("⚠️ Agent: streamed call failed (\(error.localizedDescription)); retrying without streaming")
            }
        }
        var plain = request
        plain.streams = false
        let data = try await TeachyAIRouter.sendJSON(job: .agent, hasImages: hasImages, body: body(for: plain))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentLoopError(message: "The AI sent back something Teachy could not read.")
        }
        let turn = parse(responseJSON: json)
        if !turn.content.isEmpty { request.onContent?(turn.content) }
        return turn
    }

    static func parse(responseJSON json: [String: Any]) -> AgentAssistantTurn {
        let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
        let calls = ((message["tool_calls"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, call -> AgentToolCall? in
            let function = call["function"] as? [String: Any]
            guard let name = function?["name"] as? String, !name.isEmpty else { return nil }
            return AgentToolCall(id: (call["id"] as? String) ?? "call_\(index)", name: name, arguments: (function?["arguments"] as? String) ?? "{}")
        }
        return AgentAssistantTurn(content: (message["content"] as? String) ?? "", toolCalls: calls)
    }

    private static func sendStreaming(_ request: AgentModelRequest, hasImages: Bool) async throws -> AgentAssistantTurn {
        let bytes = try await TeachyAIRouter.openStream(job: .agent, hasImages: hasImages, session: .shared, body: body(for: request))
        var accumulator = AgentStreamAccumulator()
        let lines = StreamIdleGuard.lines(from: bytes, firstByteTimeout: 90, idleTimeout: 8, isContentLine: AgentStreamAccumulator.lineStartsReply)
        for try await line in lines {
            try Task.checkCancellation()
            if accumulator.ingest(line: line) { request.onContent?(accumulator.content) }
            // Some tiers never close the stream: stop as soon as the reply is complete.
            if accumulator.isComplete { break }
        }
        if let errorMessage = accumulator.errorMessage, accumulator.content.isEmpty, !accumulator.hasToolCalls {
            throw AgentLoopError(message: errorMessage)
        }
        return accumulator.turn
    }
}
