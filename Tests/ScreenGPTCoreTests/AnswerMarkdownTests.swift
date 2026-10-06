import Foundation
import Testing
@testable import ScreenGPTCore

@Test func headingsBecomeCleanHeadingBlocks() {
    let answer = AnswerMarkdown("# Overview\n\n## Details")

    #expect(answer.blocks.count == 2)
    #expect(isHeading(answer.blocks[0].kind, level: 1))
    #expect(isHeading(answer.blocks[1].kind, level: 2))
    #expect(allText(answer.blocks[0]) == "Overview")
    #expect(allText(answer.blocks[1]) == "Details")
}

@Test func inlineFormattingStaysOnOneParagraph() {
    let answer = AnswerMarkdown("A **bold**, *soft*, `code`, and [link](https://example.com).")

    #expect(answer.blocks.count == 1)
    #expect(answer.blocks[0].kind == .paragraph)
    #expect(text(answer.blocks[0]) == "A bold, soft, code, and link.")

    let runs = Array(answer.blocks[0].content.runs)
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    #expect(runs.contains { $0.link == URL(string: "https://example.com") })
}

@Test func paragraphsAndAdjacentListsRemainSeparate() {
    let answer = AnswerMarkdown("First paragraph.\n\nSecond paragraph.\n\n- alpha\n- beta\n\nFinal paragraph.")

    #expect(answer.blocks.count == 4)
    #expect(answer.blocks.map { allText($0) } == ["First paragraph.", "Second paragraph.", "alphabeta", "Final paragraph."])
    #expect(answer.blocks[0].kind == .paragraph)
    #expect(answer.blocks[1].kind == .paragraph)
    #expect(answer.blocks[2].kind == .unorderedList)
    #expect(answer.blocks[2].children.map { allText($0) } == ["alpha", "beta"])
    #expect(answer.blocks[3].kind == .paragraph)
}

@Test func nestedListsKeepHierarchyAndOrderedItemOrdinals() {
    let answer = AnswerMarkdown("3. outer\n   1. nested one\n   2. nested two\n4. next")

    #expect(answer.blocks.count == 1)
    let outerList = answer.blocks[0]
    #expect(outerList.kind == .orderedList)
    #expect(outerList.children.count == 2)
    #expect(outerList.children.map { String(allText($0).prefix(5)) } == ["outer", "next"])
    #expect(outerList.children.map { $0.kind } == [.listItem(ordinal: 3), .listItem(ordinal: 4)])

    let nested = outerList.children[0].children
    #expect(nested.contains { $0.kind == .orderedList })
    let nestedList = nested.first { $0.kind == .orderedList }
    #expect(nestedList?.children.map { allText($0) } == ["nested one", "nested two"])
    #expect(nestedList?.children.map { $0.kind } == [.listItem(ordinal: 1), .listItem(ordinal: 2)])
}

@Test func quotesAndCodeKeepTheirTextAndCodeStaysLiteral() {
    let answer = AnswerMarkdown("> quoted  text\n\n```swift\n  let marker = \"**literal**\"  \n```\n")

    #expect(answer.blocks.count == 2)
    #expect(answer.blocks[0].kind == .blockQuote)
    #expect(allText(answer.blocks[0]) == "quoted  text")
    #expect(answer.blocks[1].kind == .codeBlock(languageHint: "swift"))
    #expect(text(answer.blocks[1]) == "  let marker = \"**literal**\"  \n")
    #expect(Array(answer.blocks[1].content.runs).allSatisfy { $0.inlinePresentationIntent == nil })
}

@Test func tableRetainsEmptyCellPositionsAndColumnAlignment() {
    let answer = AnswerMarkdown("| Left | Center | Right |\n| :--- | :---: | ---: |\n| A |  | C |")

    #expect(answer.blocks.count == 1)
    let table = answer.blocks[0]
    #expect(isTable(table.kind))
    #expect(table.children.count == 2)
    let header = table.children[0]
    let row = table.children[1]
    #expect(header.kind == .tableHeaderRow)
    #expect(isTableRow(row.kind))
    #expect(header.children.map { text($0) } == ["Left", "Center", "Right"])
    #expect(header.children.map { columnIndex($0.kind) } == [0, 1, 2])
    #expect(row.children.map { columnIndex($0.kind) } == [0, 2])
    #expect(row.children.map { allText($0) } == ["A", "C"])
    #expect(tableColumns(table.kind)?.map { $0.alignment } == [.left, .center, .right])
}

@Test func incompleteStreamingMarkupAndFenceDoNotDropVisibleText() {
    let source = "A **still open\n\n```swift\nlet answer = 42\n  "
    let answer = AnswerMarkdown(source)
    let visible = answer.blocks.map(allText).joined(separator: "\n")

    #expect(visible.contains("A "))
    #expect(visible.contains("still open"))
    #expect(visible.contains("let answer = 42"))
    #expect(visible.contains("  "))
}

@Test func unicodeAndPlainInputArePreservedAndEmptyInputHasNoBlocks() {
    let unicode = AnswerMarkdown("你好，Mira 🌍")
    #expect(unicode.blocks.count == 1)
    #expect(unicode.blocks[0].kind == .paragraph)
    #expect(allText(unicode.blocks[0]) == "你好，Mira 🌍")

    let plain = AnswerMarkdown("plain text with # and * markers")
    #expect(plain.blocks.count == 1)
    #expect(plain.blocks[0].kind == .paragraph)
    #expect(allText(plain.blocks[0]) == "plain text with # and * markers")

    #expect(AnswerMarkdown("").blocks.isEmpty)
}

private func text(_ block: AnswerMarkdown.Block) -> String {
    String(block.content.characters)
}

private func allText(_ block: AnswerMarkdown.Block) -> String {
    text(block) + block.children.map(allText).joined()
}

private func isHeading(_ kind: PresentationIntent.Kind, level: Int) -> Bool {
    kind == .header(level: level)
}

private func isTable(_ kind: PresentationIntent.Kind) -> Bool {
    if case .table(columns: _) = kind { return true }
    return false
}

private func isTableRow(_ kind: PresentationIntent.Kind) -> Bool {
    if case .tableRow(rowIndex: _) = kind { return true }
    return false
}

private func columnIndex(_ kind: PresentationIntent.Kind) -> Int? {
    if case .tableCell(columnIndex: let index) = kind { return index }
    return nil
}

private func tableColumns(_ kind: PresentationIntent.Kind) -> [PresentationIntent.TableColumn]? {
    if case .table(columns: let columns) = kind { return columns }
    return nil
}
