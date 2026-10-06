import Foundation

/// A block tree for the native answer view. Foundation parses the syntax and
/// inline styles; block identities restore the structure lost by a plain Text.
public struct AnswerMarkdown {
    public struct Block: Identifiable {
        public let id: Int
        public let kind: PresentationIntent.Kind
        public let content: AttributedString
        public let children: [Block]
    }

    public let blocks: [Block]

    public init(_ source: String) {
        guard !source.isEmpty else { blocks = []; return }
        // Throw on failure rather than returning a partial parse that could
        // silently discard part of an answer. Unclosed streaming syntax is
        // accepted by the Markdown parser; errors fall back to the full source.
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)),
              !parsed.characters.isEmpty else {
            blocks = [Block(id: 0, kind: .paragraph, content: AttributedString(source), children: [])]
            return
        }

        let root = Builder(id: -1, kind: .paragraph)
        var nodes: [Int: Builder] = [:]
        for run in parsed.runs {
            var parent = root
            // Foundation supplies the innermost component first. Reversing
            // builds nested lists, quotes and tables in their source order.
            for component in (run.presentationIntent?.components ?? []).reversed() {
                if let existing = nodes[component.identity] {
                    parent = existing
                } else {
                    let node = Builder(id: component.identity, kind: component.kind)
                    parent.children.append(node)
                    nodes[component.identity] = node
                    parent = node
                }
            }
            if parent === root {
                let node = Builder(id: -root.children.count - 2, kind: .paragraph)
                root.children.append(node)
                parent = node
            }
            var content = AttributedString(parsed[run.range])
            // The view owns block layout. Keep the inline emphasis, code and
            // links without asking Text to interpret the block a second time.
            content.presentationIntent = nil
            parent.content.append(content)
        }
        blocks = root.children.map { $0.block }
    }

    private final class Builder {
        let id: Int
        let kind: PresentationIntent.Kind
        var content = AttributedString()
        var children: [Builder] = []
        init(id: Int, kind: PresentationIntent.Kind) { self.id = id; self.kind = kind }
        var block: Block { Block(id: id, kind: kind, content: content, children: children.map { $0.block }) }
    }
}
