import Foundation

/// Errors reported while decoding a streamed model response.
public struct AIStreamError: LocalizedError, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A small Server-Sent Events decoder for the `data:` field used by Responses.
/// Call `feed(line:)` once for each line, without requiring the caller to retain
/// event state. The buffer is limited to 2 MiB to bound memory use.
public struct SSEDecoder {
    public static let maximumEventSize = 2 * 1024 * 1024

    private var dataLines: [String] = []
    private var bufferedBytes = 0
    private var lineBytes: [UInt8] = []
    private var ignoreNextLineFeed = false

    public init() {}

    /// Consumes one SSE line and returns the event's data when a blank line ends it.
    public mutating func feed(line: String) throws -> String? {
        let line = line.trimmingCharacters(in: .newlines)
        guard line.utf8.count <= Self.maximumEventSize else {
            reset()
            throw tooLargeError
        }
        return try consumeLine(line)
    }

    /// Consumes one raw stream byte while preserving blank lines as event boundaries.
    /// UTF-8 decoding is deferred until the complete line has arrived.
    public mutating func feed(byte: UInt8) throws -> String? {
        if byte == 0x0A {
            if ignoreNextLineFeed {
                ignoreNextLineFeed = false
                return nil
            }
            return try finishBufferedLine()
        }
        if byte == 0x0D {
            ignoreNextLineFeed = true
            return try finishBufferedLine()
        }
        ignoreNextLineFeed = false
        guard lineBytes.count < Self.maximumEventSize else {
            reset()
            throw tooLargeError
        }
        lineBytes.append(byte)
        return nil
    }

    /// Flushes a final unterminated line and event when the stream ends.
    public mutating func finish() throws -> String? {
        defer { reset() }
        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            if let completedEvent = try consumeLine(line) { return completedEvent }
        }
        guard !dataLines.isEmpty else { return nil }
        return dataLines.joined(separator: "\n")
    }

    private mutating func finishBufferedLine() throws -> String? {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        return try consumeLine(line)
    }

    private mutating func consumeLine(_ line: String) throws -> String? {
        if line.isEmpty {
            defer { resetEvent() }
            guard !dataLines.isEmpty else { return nil }
            return dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }

        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        let addedBytes = value.utf8.count + (dataLines.isEmpty ? 0 : 1)
        guard bufferedBytes + addedBytes <= Self.maximumEventSize else {
            reset()
            throw tooLargeError
        }
        dataLines.append(value)
        bufferedBytes += addedBytes
        return nil
    }

    private var tooLargeError: AIStreamError {
        AIStreamError(code: "stream_too_large", message: "The streamed line or event exceeded the 2 MiB limit.")
    }

    private mutating func reset() {
        lineBytes.removeAll(keepingCapacity: true)
        ignoreNextLineFeed = false
        resetEvent()
    }

    private mutating func resetEvent() {
        dataLines.removeAll(keepingCapacity: true)
        bufferedBytes = 0
    }
}

/// Accumulates text from OpenAI Responses API stream events.
public struct ResponseAccumulator {
    public private(set) var text = ""
    public private(set) var completed = false
    /// Retained in memory for manual continuation; never rendered or logged.
    public private(set) var outputItems: Data?
    private var streamedTextKeys: Set<String> = []
    private var finishedTextKeys: Set<String> = []

    public init() {}

    /// Ingests one JSON SSE payload. Returned strings are newly appended text.
    public mutating func ingest(_ json: String) throws -> String? {
        if json.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let event = root as? [String: Any],
              let type = event["type"] as? String else {
            throw AIStreamError(code: "invalid_stream_event", message: "The response stream contained invalid JSON.")
        }

        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String else {
                throw AIStreamError(code: "invalid_stream_event", message: "A text delta event had no text.")
            }
            streamedTextKeys.insert(Self.textKey(in: event))
            text += delta
            return delta.isEmpty ? nil : delta

        case "response.output_text.done":
            guard let finalText = event["text"] as? String else { return nil }
            return appendDoneText(finalText, from: event)

        case "response.refusal.done":
            guard let refusal = event["refusal"] as? String else { return nil }
            return appendDoneText(refusal, from: event)

        case "response.completed":
            let response = event["response"] as? [String: Any] ?? [:]
            if let status = response["status"] as? String, status != "completed" {
                throw AIStreamError(code: "response_not_completed", message: "The response ended with status \(status).")
            }
            if let output = response["output"] as? [[String: Any]] {
                outputItems = try JSONSerialization.data(withJSONObject: output)
            }
            if let authoritative = Self.outputText(in: response) {
                let previousText = text
                text = authoritative
                completed = true
                if authoritative.hasPrefix(previousText) {
                    let suffix = String(authoritative.dropFirst(previousText.count))
                    return suffix.isEmpty ? nil : suffix
                }
                return nil
            }
            completed = true
            return nil

        case "response.failed", "response.incomplete", "error":
            let payload = event["response"] as? [String: Any] ?? event
            let details = payload["error"] as? [String: Any]
            let code = (details?["code"] as? String) ?? (event["code"] as? String) ?? type
            let message = (details?["message"] as? String)
                ?? (event["message"] as? String)
                ?? (payload["incomplete_details"] as? [String: Any])?["reason"] as? String
                ?? (payload["status_details"] as? [String: Any])?["reason"] as? String
                ?? "The response stream ended with an error."
            throw AIStreamError(code: code, message: message)

        default:
            return nil
        }
    }

    /// Extracts the authoritative text from a completed response when output is present.
    private static func outputText(in response: [String: Any]) -> String? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        var pieces: [String] = []
        for item in output where (item["type"] as? String) == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                let type = part["type"] as? String
                let value: String?
                if type == "output_text" {
                    value = part["text"] as? String
                } else if type == "refusal" {
                    value = (part["refusal"] as? String) ?? (part["text"] as? String)
                } else {
                    value = nil
                }
                if let value {
                    pieces.append(value)
                }
            }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }

    private mutating func appendDoneText(_ finalText: String, from event: [String: Any]) -> String? {
        let key = Self.textKey(in: event)
        guard !streamedTextKeys.contains(key), finishedTextKeys.insert(key).inserted else { return nil }
        text += finalText
        return finalText.isEmpty ? nil : finalText
    }

    private static func textKey(in event: [String: Any]) -> String {
        if let itemID = event["item_id"] as? String {
            let output = event["output_index"] as? Int ?? 0
            let content = event["content_index"] as? Int ?? 0
            return "item:\(itemID):\(output):\(content)"
        }
        if let output = event["output_index"] as? Int {
            let content = event["content_index"] as? Int ?? 0
            return "output:\(output):\(content)"
        }
        return "default"
    }
}
