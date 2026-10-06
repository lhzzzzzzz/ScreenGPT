import SwiftUI
import ScreenGPTCore

/// Shared by the floating answer and saved history, including older answers.
struct AnswerText: View {
    let text: String
    var body: some View {
        MarkdownBlocks(blocks: AnswerMarkdown(text).blocks)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [AnswerMarkdown.Block]
    var spacing: CGFloat = 12
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { MarkdownBlock(block: $0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlock: View {
    let block: AnswerMarkdown.Block

    @ViewBuilder var body: some View {
        switch block.kind {
        case .header(let level):
            MarkdownInline(content: block.content, font: .system(size: headingSize(level), weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .orderedList:
            list(ordered: true)
        case .unorderedList:
            list(ordered: false)
        case .blockQuote:
            MarkdownBlocks(blocks: block.children, spacing: 8)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.18)).frame(width: 3) }
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(String(block.content.characters))
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                        .fixedSize(horizontal: true, vertical: true)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        case .table(let columns):
            MarkdownTable(block: block, columns: columns)
        case .thematicBreak:
            Divider().padding(.vertical, 3)
        default:
            if !block.content.characters.isEmpty { MarkdownInline(content: block.content) }
            if !block.children.isEmpty { MarkdownBlocks(blocks: block.children) }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 20; case 2: return 17; case 3: return 15; default: return 14 }
    }

    private func list(ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(block.children) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(item, ordered: ordered))
                        .font(.system(size: 14)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                    MarkdownBlocks(blocks: item.children, spacing: 8)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func marker(_ item: AnswerMarkdown.Block, ordered: Bool) -> String {
        if ordered, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }
}

private struct MarkdownInline: View {
    let content: AttributedString
    var font: Font = .system(size: 14)
    var body: some View {
        Text(styledContent).font(font).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var styledContent: AttributedString {
        var result = content
        for run in content.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: 12, design: .monospaced)
            result[run.range].backgroundColor = .primary.opacity(0.06)
        }
        return result
    }
}

private struct MarkdownTable: View {
    let block: AnswerMarkdown.Block
    let columns: [PresentationIntent.TableColumn]
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(block.children) { row in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            let header = row.kind == .tableHeaderRow
                            Text(cell(row, column: index))
                                .font(.system(size: 13, weight: header ? .semibold : .regular)).lineSpacing(4)
                                .multilineTextAlignment(textAlignment(columns[index].alignment))
                                .frame(width: 140, alignment: alignment(columns[index].alignment))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(.primary.opacity(header ? 0.065 : 0.025))
                                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)))
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func cell(_ row: AnswerMarkdown.Block, column: Int) -> AttributedString {
        row.children.first { $0.kind == .tableCell(columnIndex: column) }?.content ?? AttributedString()
    }
    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch value { case .center: return .center; case .right: return .trailing; default: return .leading }
    }
    private func textAlignment(_ value: PresentationIntent.TableColumn.Alignment) -> TextAlignment {
        switch value { case .center: return .center; case .right: return .trailing; default: return .leading }
    }
}
