import AppKit
import SwiftUI
import ScreenGPTCore

private let accent = Color(red: 0.10, green: 0.48, blue: 0.44)

struct CaptureToolbar: View {
    @ObservedObject var session: CaptureSession
    let glass: Bool
    var body: some View {
        HStack(spacing: 5) {
            action(.solve)
            action(.translate)
            action(.ask)
            Divider().frame(height: 19)
            Menu {
                Picker(L("原文", "Source"), selection: Binding(get: { session.source }, set: { session.updateTranslationLanguages(source: $0, target: session.target) })) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("译文", "Target"), selection: Binding(get: { session.target }, set: { session.updateTranslationLanguages(source: session.source, target: $0) })) {
                    ForEach(Language.allCases.filter { $0 != .auto }) { Text($0.title).tag($0) }
                }
                Button(L("交换语言", "Swap languages")) {
                    if session.source != .auto { session.updateTranslationLanguages(source: session.target, target: session.source) }
                }.disabled(session.source == .auto)
            } label: { Text("\(session.source.short) → \(session.target.short)").font(.system(size: 12, weight: .medium)) }
                .menuStyle(.borderlessButton).frame(width: 80).help(L("本次翻译语言", "Translation languages"))
            Spacer(minLength: 0)
            Button { session.reselect?() } label: {
                Label(L("重新框选", "Reselect"), systemImage: "crop").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle())
            }.help(L("清除当前选区和对话后重新框选", "Clear this selection and conversation to select again"))
            Button { session.close?() } label: { Image(systemName: "xmark").frame(width: 28, height: 32).contentShape(Rectangle()) }
                .help(L("退出 (Esc)", "Close (Esc)"))
        }
        .font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(Surface(glass: glass, radius: 14))
    }
    private func action(_ action: CaptureAction) -> some View {
        Button { session.run(action) } label: {
            Label(action.title, systemImage: action.icon).padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
        }
        .background(session.hasResult && session.action == action ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

struct AnswerPanel: View {
    @ObservedObject var session: CaptureSession
    let glass: Bool
    @State private var copied = false
    @FocusState private var composerFocused: Bool
    private let bottomID = "conversation-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: session.action.icon).foregroundStyle(accent)
                Text(session.action.resultTitle).font(.system(size: 14, weight: .semibold))
                Spacer()
                if session.working { ProgressView().controlSize(.small) }
                else { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
            }.padding(17).contentShape(Rectangle())
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(session.conversation.turns) { turn in
                            VStack(alignment: .leading, spacing: 18) {
                                if let question = turn.question { questionBubble(question) }
                                AnswerText(text: turn.answer)
                            }.id(turn.id)
                        }
                        if session.requestPending {
                            if let question = session.pendingQuestion { questionBubble(question) }
                            if session.answer.isEmpty && session.working {
                                Text(L("正在理解截图…", "Reading the screenshot…")).foregroundStyle(.secondary)
                            }
                            if !session.answer.isEmpty { AnswerText(text: session.answer) }
                        } else if session.conversation.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(L("关于这张截图，你想了解什么？", "What would you like to know about this screenshot?")).font(.system(size: 16, weight: .medium))
                                Text(L("输入问题后发送，还可以继续追问。", "Send a question, then follow up here.")).font(.system(size: 13)).foregroundStyle(.secondary)
                            }.padding(.top, 9)
                        }
                        if let error = session.error {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).font(.system(size: 13))
                                HStack {
                                    if session.canRetry { Button(L("重试", "Retry")) { session.retry() } }
                                    Button(L("打开设置", "Settings")) { session.settings?() }
                                }.buttonStyle(.bordered)
                            }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(19)
                }
                .onChange(of: session.pendingQuestion) { _, question in
                    if question != nil { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: session.conversation.turns.count) { _, _ in
                    if let turn = session.conversation.turns.last { proxy.scrollTo(turn.id, anchor: .top) }
                }
            }
            if session.composerExpanded { composer }
            Divider().opacity(0.6)
            HStack(spacing: 13) {
                if session.working {
                    Button { session.cancel() } label: { Label(L("停止", "Stop"), systemImage: "stop.circle") }
                } else {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.copyText, forType: .string); copied = true
                    } label: { Label(copied ? L("已复制", "Copied") : L("复制", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(session.copyText.isEmpty)
                    Button { session.save() } label: { Label(session.saved ? L("已保存", "Saved") : L("保存", "Save"), systemImage: session.saved ? "bookmark.fill" : "bookmark") }
                        .disabled(!session.canSave)
                }
                Spacer(minLength: 0)
                if session.composerExpanded {
                    Button { composerFocused = false; session.collapseComposer() } label: { Image(systemName: "chevron.down") }
                        .help(L("收起输入框", "Hide input"))
                        .accessibilityLabel(L("收起输入框", "Hide input"))
                } else {
                    Button { session.openQuestion() } label: { Label(L("追问", "Follow up"), systemImage: "bubble.left") }
                }
            }.font(.system(size: 12)).buttonStyle(.plain).padding(16)
        }
        .onChange(of: session.copyText) { _, _ in copied = false }
        .onChange(of: session.composerFocus) { _, _ in composerFocused = true }
        .modifier(Surface(glass: glass, radius: 18))
    }

    private func questionBubble(_ question: String) -> some View {
        Text(question).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if session.draft.isEmpty {
                    Text(L("输入问题…", "Ask a question…")).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false)
                }
                TextEditor(text: $session.draft).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(height: 52).focused($composerFocused)
                    .accessibilityLabel(L("问题输入框", "Question input"))
                    .onExitCommand { session.close?() }
            }
            HStack {
                Text(L("⌘↩ 发送 · 回车换行", "⌘↩ to send · Return for a new line")).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { session.sendQuestion() } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 27, height: 27) }
                    .buttonStyle(.plain).foregroundStyle(session.canSend ? Color.white : Color.secondary)
                    .background(session.canSend ? accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!session.canSend).keyboardShortcut(.return, modifiers: .command)
                    .help(L("发送问题 (⌘↩)", "Send question (⌘↩)"))
                    .accessibilityLabel(L("发送问题", "Send question"))
            }
        }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.bottom, 12)
            .onAppear { composerFocused = true }
    }
}
