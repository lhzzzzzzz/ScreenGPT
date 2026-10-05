import Foundation
import Testing
@testable import ScreenGPTCore

@Test func sseCombinesDataLinesAndIgnoresCommentsAndOtherFields() throws {
    var decoder = SSEDecoder()
    #expect(try decoder.feed(line: ": keepalive\r\n") == nil)
    #expect(try decoder.feed(line: "event: response.output_text.delta\r\n") == nil)
    #expect(try decoder.feed(line: "data: {\"type\":\"response.output_text.delta\",\r\n") == nil)
    #expect(try decoder.feed(line: "data: \"delta\":\"Hello\"}\r\n") == nil)
    #expect(try decoder.feed(line: "\r\n") == "{\"type\":\"response.output_text.delta\",\n\"delta\":\"Hello\"}")
    #expect(try decoder.finish() == nil)
}

@Test func finishFlushesUnterminatedEvent() throws {
    var decoder = SSEDecoder()
    #expect(try decoder.feed(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"end\"}") == nil)
    #expect(try decoder.finish() == "{\"type\":\"response.output_text.delta\",\"delta\":\"end\"}")
}

@Test func byteDecoderPreservesMultibyteUTF8AndSeparatesFrames() throws {
    var decoder = SSEDecoder()
    let first = #"data: {"type":"response.output_text.delta","delta":"你好🌍"}"#
    let second = #"data: {"type":"response.output_text.delta","delta":"second"}"#
    let wire = Data("\(first)\r\n\r\n\(second)\n\n".utf8)
    var events: [String] = []

    for byte in wire {
        if let event = try decoder.feed(byte: byte) { events.append(event) }
    }

    #expect(events == [
        #"{"type":"response.output_text.delta","delta":"你好🌍"}"#,
        #"{"type":"response.output_text.delta","delta":"second"}"#
    ])
    #expect(try decoder.finish() == nil)
}

@Test func byteDecoderAcceptsCROnlySeparators() throws {
    var decoder = SSEDecoder()
    let wire = Data("data: first\r\rdata: second\r\r".utf8)
    var events: [String] = []
    for byte in wire {
        if let event = try decoder.feed(byte: byte) { events.append(event) }
    }
    #expect(events == ["first", "second"])
}

@Test func byteDecoderFinishFlushesAnUnterminatedEvent() throws {
    var decoder = SSEDecoder()
    for byte in Data("data: final event".utf8) {
        #expect(try decoder.feed(byte: byte) == nil)
    }
    #expect(try decoder.finish() == "final event")
    #expect(try decoder.finish() == nil)
}

@Test func byteDecoderBoundsLineLength() throws {
    var decoder = SSEDecoder()
    let oversizedComment = Data((":" + String(repeating: "x", count: SSEDecoder.maximumEventSize)).utf8)
    var receivedError: AIStreamError?
    do {
        for byte in oversizedComment {
            _ = try decoder.feed(byte: byte)
        }
    } catch let error as AIStreamError {
        receivedError = error
    }
    #expect(receivedError?.code == "stream_too_large")
    #expect(try decoder.finish() == nil)
}

@Test func doneSentinelDoesNotCompleteOrProduceAnError() throws {
    var accumulator = ResponseAccumulator()
    #expect(try accumulator.ingest("[DONE]") == nil)
    #expect(!accumulator.completed)
    #expect(accumulator.text == "")
}

@Test func sseRejectsOversizedEvent() throws {
    var decoder = SSEDecoder()
    try expectStreamError(code: "stream_too_large") {
        _ = try decoder.feed(line: "data: " + String(repeating: "x", count: SSEDecoder.maximumEventSize + 1))
    }
    #expect(try decoder.finish() == nil)
}

@Test func sseBoundsTotalDataAcrossMultipleLines() throws {
    var decoder = SSEDecoder()
    let line = String(repeating: "x", count: 700_000)
    #expect(try decoder.feed(line: "data: " + line) == nil)
    #expect(try decoder.feed(line: "data: " + line) == nil)
    try expectStreamError(code: "stream_too_large") {
        _ = try decoder.feed(line: "data: " + line)
    }
    #expect(try decoder.finish() == nil)
}

@Test func completedResponseUsesAuthoritativeOutputWithoutDuplicatingDeltas() throws {
    var accumulator = ResponseAccumulator()
    #expect(try accumulator.ingest(#"{"type":"response.created","response":{"id":"resp_123","status":"in_progress"}}"#) == nil)
    #expect(try accumulator.ingest(#"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello"}"#) == "Hello")
    #expect(try accumulator.ingest(#"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":0,"text":"Hello world"}"#) == nil)

    let final = #"{"type":"response.completed","response":{"id":"resp_123","status":"completed","output":[{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello world","annotations":[]}]}]}}"#
    #expect(try accumulator.ingest(final) == " world")
    #expect(accumulator.text == "Hello world")
    #expect(accumulator.completed)
}

@Test func completedResponseWithNoOutputPreservesStreamedText() throws {
    var accumulator = ResponseAccumulator()
    _ = try accumulator.ingest(#"{"type":"response.output_text.delta","delta":"Kept"}"#)
    _ = try accumulator.ingest(#"{"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[]}}"#)
    #expect(accumulator.text == "Kept")
    #expect(accumulator.completed)
}

@Test func refusalEventsProduceTextAndCompleteFromFinalOutput() throws {
    var accumulator = ResponseAccumulator()
    #expect(try accumulator.ingest(#"{"type":"response.refusal.delta","item_id":"msg_1","delta":"I can’t help with that."}"#) == "I can’t help with that.")
    #expect(try accumulator.ingest(#"{"type":"response.refusal.done","item_id":"msg_1","refusal":"I can’t help with that."}"#) == nil)
    _ = try accumulator.ingest(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I can’t help with that."}]}]}}"#)
    #expect(accumulator.text == "I can’t help with that.")
    #expect(accumulator.completed)
}

@Test func doneFallbackAddsEachDistinctContentChunkOnce() throws {
    var accumulator = ResponseAccumulator()
    let first = #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":0,"text":"First."}"#
    let second = #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":1,"text":" Second."}"#
    #expect(try accumulator.ingest(first) == "First.")
    #expect(try accumulator.ingest(first) == nil)
    #expect(try accumulator.ingest(second) == " Second.")
    #expect(accumulator.text == "First. Second.")
}

@Test func failedAndIncompleteResponsesAreErrors() throws {
    var failed = ResponseAccumulator()
    try expectStreamError(code: "server_error", message: "Generation failed.") {
        _ = try failed.ingest(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"Generation failed."}}}"#)
    }

    var incomplete = ResponseAccumulator()
    try expectStreamError(code: "response.incomplete", message: "max_output_tokens") {
        _ = try incomplete.ingest(#"{"type":"response.incomplete","response":{"status":"incomplete","status_details":{"reason":"max_output_tokens"}}}"#)
    }
}

@Test func rootErrorPreservesCodeAndMessage() throws {
    var accumulator = ResponseAccumulator()
    try expectStreamError(code: "rate_limit_exceeded", message: "Please retry later.") {
        _ = try accumulator.ingest(#"{"type":"error","code":"rate_limit_exceeded","message":"Please retry later."}"#)
    }
}

@Test func completedEventCannotMarkNonCompletedStatusAsSuccess() throws {
    var accumulator = ResponseAccumulator()
    try expectStreamError(code: "response_not_completed") {
        _ = try accumulator.ingest(#"{"type":"response.completed","response":{"status":"incomplete"}}"#)
    }
    #expect(!accumulator.completed)
}

@Test func truncatedJSONPayloadIsRejected() throws {
    var accumulator = ResponseAccumulator()
    try expectStreamError(code: "invalid_stream_event") {
        _ = try accumulator.ingest(#"{"type":"response.output_text.delta","delta":"unfinished""#)
    }
}

private func expectStreamError(
    code: String,
    message: String? = nil,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("Expected AIStreamError with code \(code)")
    } catch let error as AIStreamError {
        #expect(error.code == code)
        if let message {
            #expect(error.message == message)
        }
    } catch {
        Issue.record("Expected AIStreamError, received \(error)")
    }
}
