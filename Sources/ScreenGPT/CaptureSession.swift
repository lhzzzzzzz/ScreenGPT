import AppKit
import Combine
import ScreenGPTCore

@MainActor final class CaptureSession: ObservableObject {
    @Published var action: CaptureAction = .translate
    @Published private(set) var source: Language
    @Published private(set) var target: Language
    @Published var answer = ""
    @Published var working = false
    @Published var error: String?
    @Published var saved = false
    @Published var hasResult = false
    @Published var conversation = ScreenshotConversation()
    @Published var draft = ""
    @Published var composerExpanded = false
    @Published var composerFocus = 0
    @Published private(set) var requestPending = false
    @Published private(set) var pendingQuestion: String?
    private(set) var image: Data?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var entryID = UUID()
    private var answeredSource: Language?
    private var answeredTarget: Language?
    private var configuration: ModelConfiguration?
    private var selectedModel: ModelChoice?
    private let preferences: Preferences
    private let account: ChatGPTAccount
    private let history: HistoryStore
    private struct Request {
        let prompt: String
        let question: String?
        let source: Language
        let target: Language
        let language: InterfaceLanguage
    }
    private var pending: Request?
    var reveal: (() -> Void)?
    var close: (() -> Void)?
    var reselect: (() -> Void)?
    var settings: (() -> Void)?
    var move: ((CGSize, Bool) -> Void)?
    var preview = false
    // A single selection is shared by all displays until explicit reselection.
    var selectionLocked = false

    init(preferences: Preferences, account: ChatGPTAccount, history: HistoryStore) {
        self.preferences = preferences; self.account = account; self.history = history
        source = preferences.source; target = preferences.target
    }
    var canSend: Bool { image != nil && !working && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRetry: Bool { requestPending && pending != nil && !working }
    var canSave: Bool { !conversation.turns.isEmpty && !working && !requestPending && !preview && !saved }
    var copyText: String {
        var text = conversation.transcript(questionLabel: L("提问", "Question"))
        if requestPending && !answer.isEmpty {
            if !text.isEmpty { text += "\n\n---\n\n" }
            if let pendingQuestion { text += "### \(L("提问", "Question"))\n\n\(pendingQuestion)\n\n" }
            text += answer
        }
        return text
    }
    func select(image: Data) { reset(); self.image = image }
    func reset() { clearConversation(); image = nil }
    private func clearConversation() {
        cancel(silent: true)
        conversation = ScreenshotConversation(); answer = ""; error = nil; hasResult = false; saved = false
        draft = ""; composerExpanded = false; requestPending = false; pendingQuestion = nil; pending = nil
        answeredSource = nil; answeredTarget = nil; configuration = nil; selectedModel = nil; entryID = UUID()
    }
    func cancel(silent: Bool = false) {
        let wasWorking = working
        requestID = UUID(); task?.cancel(); task = nil; working = false
        if !silent && wasWorking { error = L("已停止。可以重试，或输入新的问题。", "Stopped. Retry or enter a new question.") }
    }
    func openQuestion() {
        guard image != nil else { return }
        if !hasResult {
            action = .ask; hasResult = true; configuration = preferences.configuration(for: .ask)
        }
        composerExpanded = true; reveal?(); composerFocus += 1
    }
    func collapseComposer() { composerExpanded = false; reveal?() }
    func updateTranslationLanguages(source: Language, target: Language) {
        guard target != .auto, source != self.source || target != self.target else { return }
        self.source = source; self.target = target
        // A language choice before the first translation only configures the task.
        // Swapping both languages is atomic and rapid changes share the cancellable
        // request lifecycle, so old responses cannot overwrite the final choice.
        guard action == .translate, hasResult else { return }
        run(.translate, delay: .milliseconds(300), preservingComposer: true)
    }
    func run(_ action: CaptureAction) { run(action, delay: .zero, preservingComposer: false) }
    private func run(_ action: CaptureAction, delay: Duration, preservingComposer: Bool) {
        if action == .ask { openQuestion(); return }
        guard image != nil else { return }
        let previousDraft = draft, wasExpanded = composerExpanded
        clearConversation(); self.action = action; hasResult = true
        if preservingComposer { draft = previousDraft; composerExpanded = wasExpanded }
        configuration = preferences.configuration(for: action)
        let language = preferences.interfaceLanguage
        perform(Request(prompt: AIClient.prompt(action: action, source: source, target: target, language: language), question: nil, source: source, target: target, language: language), delay: delay)
    }
    func sendQuestion() {
        guard canSend else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasResult { openQuestion() }
        draft = ""
        perform(Request(prompt: question, question: question, source: source, target: target, language: preferences.interfaceLanguage))
    }
    func retry() { if canRetry, let pending { perform(pending) } }

    private func perform(_ request: Request, delay: Duration = .zero) {
        guard let image else { return }
        cancel(silent: true)
        pending = request; pendingQuestion = request.question; requestPending = true
        hasResult = true; saved = false; answer = ""; error = nil; working = true
        if answeredSource == nil { answeredSource = request.source; answeredTarget = request.target }
        reveal?()
        let id = requestID
        let configuration = configuration ?? preferences.configuration(for: action)
        let context = conversation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                guard requestID == id else { return }
                let reply: AIClient.Reply
                if preview {
                    let previewLanguage = action == .translate && context.turns.isEmpty
                        ? (request.target == .chinese ? InterfaceLanguage.chinese : .english) : request.language
                    let text = PreviewAnswers.answer(action: action, followUp: !context.turns.isEmpty, language: previewLanguage)
                    // Exercise the same streaming/stop lifecycle without a network request.
                    let characters = Array(text)
                    for count in stride(from: 24, to: characters.count, by: 24) {
                        try await Task.sleep(for: .milliseconds(25))
                        guard requestID == id else { return }
                        answer = String(characters.prefix(count))
                    }
                    reply = AIClient.Reply(text: text, outputItems: nil)
                } else {
                    guard account.active?.connected == true else { throw AppFailure(L("先登录 ChatGPT，即可用套餐额度处理截图。", "Sign in to ChatGPT to use your plan with screenshots.")) }
                    if account.models.isEmpty { await account.loadModels() }
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    guard let model = selectedModel ?? (configuration.model.isEmpty ? account.models.first : account.models.first(where: { $0.slug == configuration.model })) else {
                        throw AppFailure(L("所选模型当前不可用，请在账号设置中重新选择。", "The selected model is unavailable. Choose another in account settings."))
                    }
                    selectedModel = model
                    reply = try await AIClient(account: account).answer(image: image, prompt: request.prompt, conversation: context, model: model, effort: configuration.effort, language: request.language) { [weak self] text in
                        guard let self, self.requestID == id else { return }; self.answer = text
                    }
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                conversation.append(prompt: request.prompt, question: request.question, answer: reply.text, outputItems: reply.outputItems)
                answer = reply.text; working = false; requestPending = false; pendingQuestion = nil
                if preferences.automaticallySave { save() }
            } catch {
                guard requestID == id else { return }
                working = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func save() {
        guard let image, canSave else { return }
        do {
            try history.save(HistoryEntry(id: entryID, action: action, source: answeredSource ?? source, target: answeredTarget ?? target, answer: copyText, image: image))
            saved = true
        } catch { self.error = L("保存失败：\(error.localizedDescription)", "Could not save: \(error.localizedDescription)") }
    }
}

private enum PreviewAnswers {
    static func answer(action: CaptureAction, followUp: Bool, language: InterfaceLanguage) -> String {
        if followUp {
            return language.text("这次追问仍基于**同一张截图**：两条直角边是 3 和 4，斜边是 5。\n\n可以继续输入问题；重新框选会清空本次对话。\n\n*界面预览示例，未调用模型。*", "This follow-up still uses **the same screenshot**: the legs are 3 and 4, and the hypotenuse is 5.\n\nYou can keep asking questions. Reselecting starts a fresh conversation.\n\n*Interface preview; no model request was made.*")
        }
        switch action {
        case .translate:
            return language.text("# 阅读图形，理解关系\n\n## 直角三角形\n\n- 两条直角边分别为 **3** 和 **4**。\n- 求斜边的长度，保留图中的对应关系。\n\n> 图形与文字应结合阅读。\n\n*界面预览示例，未调用模型。*", "# Read the diagram\n\n## A right triangle\n\n- The two legs have lengths **3** and **4**.\n- Find the length of the hypotenuse.\n\n> Read text and figures together.\n\n*Interface preview; no model request was made.*")
        case .solve:
            return language.text("# 答案：5\n\n## 解题步骤\n\n1. 根据勾股定理，c² = 3² + 4²。\n2. 计算得 c² = 25，所以 c = **5**。\n\n| 边 | 长度 |\n| :--- | ---: |\n| 直角边 a | 3 |\n| 直角边 b | 4 |\n| 斜边 c | **5** |\n\n## 计算示例\n\n使用 `sqrt` 计算平方根：\n\n```python\nfrom math import sqrt\nc = sqrt(3 ** 2 + 4 ** 2)\nprint(c)  # 5.0\n```\n\n*界面预览示例，未调用模型。*", "# Answer: 5\n\n## Steps\n\n1. By the Pythagorean theorem, c² = 3² + 4².\n2. So c² = 25 and c = **5**.\n\n| Side | Length |\n| :--- | ---: |\n| Leg a | 3 |\n| Leg b | 4 |\n| Hypotenuse c | **5** |\n\n## Calculation\n\nUse `sqrt` for the square root:\n\n```python\nfrom math import sqrt\nc = sqrt(3 ** 2 + 4 ** 2)\nprint(c)  # 5.0\n```\n\n*Interface preview; no model request was made.*")
        case .ask:
            return language.text("这张截图展示了一道**直角三角形**题目。两条直角边分别是 3 和 4，可以用勾股定理求出斜边为 **5**。\n\n可以继续追问某个步骤或符号的含义。\n\n*界面预览使用固定示例回答，未调用模型。*", "This screenshot shows a **right-triangle problem**. Its legs are 3 and 4, so the Pythagorean theorem gives a hypotenuse of **5**.\n\nYou can ask about a step or a symbol next.\n\n*This is a fixed interface preview, not a model response.*")
        }
    }
}
