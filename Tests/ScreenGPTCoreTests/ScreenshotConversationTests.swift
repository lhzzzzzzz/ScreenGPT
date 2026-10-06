import Foundation
import Testing
@testable import ScreenGPTCore

@Test func firstScreenshotInputContainsPromptAndExactlyOneImage() throws {
    let conversation = ScreenshotConversation()
    let input = conversation.input(prompt: "What is here?", imageURL: "data:image/png;base64,abc", detail: "high")

    #expect(input.count == 1)
    #expect(input[0]["role"] as? String == "user")
    let content = try contentItems(in: input[0])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "input_text")
    #expect(content[0]["text"] as? String == "What is here?")
    #expect(content[1]["type"] as? String == "input_image")
    #expect(content[1]["image_url"] as? String == "data:image/png;base64,abc")
    #expect(content[1]["detail"] as? String == "high")
}

@Test func followUpInputReplaysTurnsInOrderAndIncludesScreenshotOnlyOnce() throws {
    var conversation = ScreenshotConversation()
    conversation.append(prompt: "Initial task", question: "First question", answer: "First answer", outputItems: try outputData([
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "First answer"]]]
    ]))
    conversation.append(prompt: "Follow-up task", question: "Second question", answer: "Second answer", outputItems: try outputData([
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Second answer"]]]
    ]))

    let input = conversation.input(prompt: "Current task", imageURL: "screenshot-url", detail: "auto")

    #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])
    let users = input.filter { $0["role"] as? String == "user" }
    let texts = try users.map { try contentItems(in: $0).first?["text"] as? String }
    #expect(texts == ["Initial task", "Follow-up task", "Current task"])

    let imageCount = try users.flatMap { try contentItems(in: $0) }
        .filter { $0["type"] as? String == "input_image" }
        .count
    #expect(imageCount == 1)
}

@Test func replayPreservesCompleteOutputItemsIncludingEncryptedReasoningAndPhase() throws {
    let output: [[String: Any]] = [
        ["id": "rs_1", "type": "reasoning", "encrypted_content": "opaque-ciphertext", "summary": [["type": "summary_text", "text": "hidden summary"]]],
        ["id": "msg_1", "type": "message", "role": "assistant", "phase": "final", "status": "completed", "provider_extension": ["keep": true], "content": [["type": "output_text", "text": "Visible answer", "annotations": []]]]
    ]
    var conversation = ScreenshotConversation()
    conversation.append(prompt: "Task", question: "Question", answer: "Visible answer", outputItems: try outputData(output))

    let input = conversation.input(prompt: "Next task", imageURL: "image", detail: "auto")
    #expect(input.count == 4)
    #expect(input[1]["type"] as? String == "reasoning")
    #expect(input[1]["encrypted_content"] as? String == "opaque-ciphertext")
    #expect(input[1]["summary"] as? [[String: String]] == [["type": "summary_text", "text": "hidden summary"]])
    #expect(input[2]["phase"] as? String == "final")
    #expect(input[2]["provider_extension"] as? [String: Bool] == ["keep": true])
    #expect(input[2]["content"] as? [[String: Any]] != nil)
}

@Test func emptyOrMissingOutputFallsBackToVisibleAssistantText() throws {
    var conversation = ScreenshotConversation()
    conversation.append(prompt: "Task one", question: nil, answer: "Answer from missing output", outputItems: nil)
    conversation.append(prompt: "Task two", question: nil, answer: "Answer from empty output", outputItems: try outputData([]))

    let input = conversation.input(prompt: "Task three", imageURL: "image", detail: "auto")

    #expect(input.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])
    #expect(input[1]["content"] as? String == "Answer from missing output")
    #expect(input[3]["content"] as? String == "Answer from empty output")
}

@Test func transcriptShowsOriginalQuestionAndAnswerWithoutHiddenTaskPrompt() {
    var conversation = ScreenshotConversation()
    conversation.append(
        prompt: "private hidden task prompt",
        question: "user's original question",
        answer: "Visible answer",
        outputItems: nil
    )

    let transcript = conversation.transcript(questionLabel: "Question")

    #expect(transcript.contains("Question\n\nuser's original question"))
    #expect(transcript.contains("Visible answer"))
    #expect(!transcript.contains("private hidden task prompt"))
}

@Test func freshScreenshotConversationHasNoPriorTurnsOrImageState() throws {
    var previous = ScreenshotConversation()
    previous.append(prompt: "Old task", question: "Old question", answer: "Old answer", outputItems: nil)

    let fresh = ScreenshotConversation()
    let input = fresh.input(prompt: "New task", imageURL: "new-screenshot", detail: "low")

    #expect(fresh.turns.isEmpty)
    #expect(input.count == 1)
    let content = try contentItems(in: input[0])
    #expect(content.compactMap { $0["text"] as? String } == ["New task"])
    #expect(content.filter { $0["type"] as? String == "input_image" }.compactMap { $0["image_url"] as? String } == ["new-screenshot"])
}

@Test func responseAccumulatorRetainsOutputOnlyForCompletedResponses() throws {
    var completed = ResponseAccumulator()
    #expect(completed.outputItems == nil)
    _ = try completed.ingest(#"{"type":"response.output_text.delta","delta":"partial"}"#)
    #expect(completed.outputItems == nil)
    _ = try completed.ingest(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"cipher"},{"type":"message","phase":"final","content":[{"type":"output_text","text":"done"}]}]}}"#)
    #expect(completed.completed)

    let captured = try #require(completed.outputItems)
    let output = try #require(JSONSerialization.jsonObject(with: captured) as? [[String: Any]])
    #expect(output[0]["encrypted_content"] as? String == "cipher")
    #expect(output[1]["phase"] as? String == "final")

    var failed = ResponseAccumulator()
    #expect(throws: AIStreamError.self) {
        _ = try failed.ingest(#"{"type":"response.failed","response":{"status":"failed","output":[{"type":"message"}]}}"#)
    }
    #expect(failed.outputItems == nil)

    var incomplete = ResponseAccumulator()
    #expect(throws: AIStreamError.self) {
        _ = try incomplete.ingest(#"{"type":"response.incomplete","response":{"status":"incomplete","output":[{"type":"message"}]}}"#)
    }
    #expect(incomplete.outputItems == nil)
}

@Test func interfaceLanguageHasStableRawValuesTitlesAndTextSelection() {
    #expect(InterfaceLanguage.chinese.rawValue == "zh-Hans")
    #expect(InterfaceLanguage.english.rawValue == "en")
    #expect(InterfaceLanguage.chinese.title == "简体中文")
    #expect(InterfaceLanguage.english.title == "English")
    #expect(InterfaceLanguage.chinese.text("中文", "English text") == "中文")
    #expect(InterfaceLanguage.english.text("中文", "English text") == "English text")
}

private func contentItems(in item: [String: Any]) throws -> [[String: Any]] {
    try #require(item["content"] as? [[String: Any]])
}

private func outputData(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: items)
}
