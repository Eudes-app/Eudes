import Foundation

/// Incremental UTF-8 SSE framing. Limits apply before decoding, including to
/// servers that never send a newline. Handles CR, LF, CRLF and split UTF-8.
struct SSEDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private var firstLine = true
    let maxEventBytes: Int

    init(maxEventBytes: Int = 1_048_576) { self.maxEventBytes = maxEventBytes }

    mutating func feed(_ byte: UInt8) throws -> String? {
        if byte == 10 && previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 { return try consumeLine() }
        line.append(byte)
        guard line.count + eventBytes <= maxEventBytes else { throw EudesError.responseTooLarge }
        return nil
    }

    mutating func finish() throws -> String? {
        if !line.isEmpty { _ = try consumeLine() }
        return dispatch()
    }

    private mutating func consumeLine() throws -> String? {
        guard var text = String(bytes: line, encoding: .utf8) else { throw EudesError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine { text = text.replacingOccurrences(of: "\u{FEFF}", with: ""); firstLine = false }
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "data" else { return nil }
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        eventBytes += value.utf8.count + 1
        guard eventBytes <= maxEventBytes else { throw EudesError.responseTooLarge }
        dataLines.append(value)
        return nil
    }

    private mutating func dispatch() -> String? {
        defer { dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
}

struct CompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
            var reasoning: String?
            var reasoningContent: String?
            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
            }
        }
        var delta: Delta?
        var finishReason: String?
        enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
    }
    var choices: [Choice]?
    var error: APIError?
    struct APIError: Decodable { var message: String? }

    static func parse(_ payload: String) throws -> (text: String, reasoning: String, finished: Bool, finishReason: String?) {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return ("", "", true, nil) }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Self.self, from: data),
              chunk.error == nil, let choices = chunk.choices else { throw EudesError.malformedStream }
        // Empty choices are valid usage-only events. Only choice zero is requested.
        guard let choice = choices.first else { return ("", "", false, nil) }
        return (choice.delta?.content ?? "", choice.delta?.reasoningContent ?? choice.delta?.reasoning ?? "", choice.finishReason != nil, choice.finishReason)
    }
}

/// Responses semantic SSE events. Never concatenate final snapshots with deltas.
struct ResponsesEvent {
    static func parse(_ payload: String) throws -> (text: String, reasoning: String, finished: Bool) {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw EudesError.malformedStream }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String else { throw EudesError.malformedStream }
            return (delta, "", false)
        case "response.reasoning_summary_text.delta":
            guard let delta = event["delta"] as? String else { throw EudesError.malformedStream }
            return ("", delta, false)
        case "response.completed":
            guard let response = event["response"] as? [String: Any],
                  response["status"] as? String == "completed" else { throw EudesError.malformedStream }
            return ("", "", true)
        case "response.failed", "error": throw EudesError.responseFailed
        case "response.incomplete": throw EudesError.responseIncomplete
        case "response.output_item.added", "response.output_item.done":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else {
                throw EudesError.malformedStream
            }
            guard kind == "message" || kind == "reasoning" else { throw EudesError.unsupportedResponse }
            return ("", "", false)
        default:
            // Lifecycle, usage, reasoning and text.done snapshots do not contain display deltas.
            guard type.hasPrefix("response.") else { throw EudesError.malformedStream }
            return ("", "", false)
        }
    }
}
