import Foundation

/// One screenshot's completed exchanges. Failed or cancelled requests are never
/// committed, so retries cannot duplicate user turns or send partial answers.
public struct ScreenshotConversation {
    public struct Turn: Identifiable {
        public let id = UUID()
        public let question: String?
        public let answer: String
        let prompt: String
        let outputItems: Data?
    }
    public private(set) var turns: [Turn] = []
    public init() {}

    public mutating func append(prompt: String, question: String?, answer: String, outputItems: Data?) {
        turns.append(Turn(question: question, answer: answer, prompt: prompt, outputItems: outputItems))
    }

    /// SIWC HTTP is stateless. Resend this selection and complete output items,
    /// including encrypted reasoning and assistant phase, for each follow-up.
    /// https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
    /// https://developers.openai.com/api/docs/guides/conversation-state
    public func input(prompt: String, imageURL: String, detail: String) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for (index, turn) in turns.enumerated() {
            items.append(userItem(turn.prompt, imageURL: index == 0 ? imageURL : nil, detail: detail))
            if let data = turn.outputItems,
               let output = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !output.isEmpty {
                items.append(contentsOf: output)
            } else {
                items.append(["role": "assistant", "content": turn.answer])
            }
        }
        items.append(userItem(prompt, imageURL: turns.isEmpty ? imageURL : nil, detail: detail))
        return items
    }

    public func transcript(questionLabel: String) -> String {
        turns.map { turn in
            if let question = turn.question {
                return "### \(questionLabel)\n\n\(question)\n\n\(turn.answer)"
            }
            return turn.answer
        }.joined(separator: "\n\n---\n\n")
    }

    private func userItem(_ prompt: String, imageURL: String?, detail: String) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        if let imageURL { content.append(["type": "input_image", "image_url": imageURL, "detail": detail]) }
        return ["role": "user", "content": content]
    }
}
