import AppKit
import SwiftUI
import ScreenGPTCore

private let accent = Color(red: 0.10, green: 0.48, blue: 0.44)

struct FrostedSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .withinWindow; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
struct Surface: ViewModifier {
    let glass: Bool
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content.background {
            if glass { FrostedSurface() } else { Color(nsColor: .windowBackgroundColor) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 7)
    }
}
struct CaptureToolbar: View {
    @ObservedObject var session: CaptureSession
    let glass: Bool
    var body: some View {
        HStack(spacing: 5) {
            Button { session.run(.solve) } label: { Label("做题", systemImage: "sparkles").padding(.horizontal, 8).padding(.vertical, 8) }
                .buttonStyle(.plain).background(session.hasResult && session.action == .solve ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            Button { session.run(.translate) } label: { Label("翻译", systemImage: "character.bubble").padding(.horizontal, 8).padding(.vertical, 8) }
                .buttonStyle(.plain).background(session.hasResult && session.action == .translate ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            Divider().frame(height: 19)
            Menu {
                Picker("原文", selection: $session.source) { ForEach(Language.allCases) { Text($0.title).tag($0) } }
                Picker("译文", selection: $session.target) { ForEach(Language.allCases.filter { $0 != .auto }) { Text($0.title).tag($0) } }
                Button("交换语言") { if session.source != .auto { swap(&session.source, &session.target) } }.disabled(session.source == .auto)
            } label: { Text("\(session.source.short) → \(session.target.short)").font(.system(size: 12, weight: .medium)) }
            .menuStyle(.borderlessButton).frame(width: 66).help("本次翻译语言")
            Spacer(minLength: 0)
            Button { session.reselect?() } label: { Image(systemName: "crop").frame(width: 24, height: 28) }.help("重新框选")
            Button { session.close?() } label: { Image(systemName: "xmark").frame(width: 24, height: 28) }.help("退出 (Esc)")
        }
        .font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(Surface(glass: glass, radius: 14))
    }
}
struct AnswerPanel: View {
    @ObservedObject var session: CaptureSession
    let glass: Bool
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: session.action.icon).foregroundStyle(accent)
                Text(session.action == .solve ? "题目解答" : "译文").font(.system(size: 14, weight: .semibold))
                Spacer()
                if session.working { ProgressView().controlSize(.small) }
                else { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
            }
            .padding(17).contentShape(Rectangle())
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.answer.isEmpty && session.working {
                        Text("正在理解截图…").foregroundStyle(.secondary)
                        Text("图形、文字和标注会一起阅读。")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    if !session.answer.isEmpty { AnswerText(text: session.answer) }
                    if let error = session.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).font(.system(size: 13))
                            HStack {
                                Button("重试") { session.run(session.action) }
                                Button("打开设置") { session.settings?() }
                            }.buttonStyle(.bordered)
                        }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(19)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.6)
            HStack(spacing: 15) {
                if session.working {
                    Button { session.cancel() } label: { Label("停止", systemImage: "stop.circle") }
                } else {
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.answer, forType: .string); copied = true
                    } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }.disabled(session.answer.isEmpty)
                    Button { session.save() } label: { Label(session.saved ? "已保存" : "保存", systemImage: session.saved ? "bookmark.fill" : "bookmark") }.disabled(session.answer.isEmpty || session.error != nil || session.preview || session.saved)
                }
                Spacer()
                Text(session.preview ? "界面预览" : "ScreenGPT").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).buttonStyle(.plain).padding(16)
        }
        .onChange(of: session.answer) { _, _ in copied = false }
        .modifier(Surface(glass: glass, radius: 18))
    }
}
struct AnswerText: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var account: ChatGPTAccount
    @ObservedObject var history: HistoryStore
    private var page: String {
        get { app.settingsPage }
        nonmutating set { app.settingsPage = newValue }
    }
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let icon = NSImage(named: "AppIcon") { Image(nsImage: icon).resizable().frame(width: 38, height: 38) }
                    else { Image(systemName: "viewfinder").font(.system(size: 27)).foregroundStyle(accent) }
                    Text("ScreenGPT").font(.system(size: 17, weight: .semibold))
                }.padding(.bottom, 28).padding(.top, 25)
                navigation("general", "通用", "slider.horizontal.3")
                navigation("account", "ChatGPT 账号", "person.crop.circle")
                navigation("history", "已保存", "clock")
                navigation("about", "关于", "info.circle")
                Spacer()
                Button { app.beginCapture() } label: {
                    HStack { Image(systemName: "viewfinder"); Text("开始框选"); Spacer() }.padding(10)
                }.buttonStyle(.plain).foregroundStyle(.white).background(accent, in: RoundedRectangle(cornerRadius: 10))
                Text(preferences.shortcutLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 10)
            }.padding(.horizontal, 17).frame(width: 195).background(.ultraThinMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let message = app.message {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text(message).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                            Button { app.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    switch page {
                    case "account": accountPage
                    case "history": historyPage
                    case "about": aboutPage
                    default: generalPage
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 640).tint(accent)
        .onReceive(timer) { _ in app.refreshPermission() }
        .onAppear { app.refreshPermission(); if account.active?.connected == true && account.models.isEmpty { Task { await account.loadModels() } } }
    }
    private func navigation(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { page = id } label: { Label(title, systemImage: icon).font(.system(size: 13, weight: page == id ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(11) }
            .buttonStyle(.plain).background(page == id ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 27, weight: .semibold)); Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.065)))
    }
    private var generalPage: some View {
        Group {
            heading("看见，即可提问。", "一个快捷键，把屏幕上的内容变成答案。")
            if !app.screenPermission || account.active?.connected != true {
                card {
                    Text("准备好就开始").font(.system(size: 14, weight: .semibold))
                    HStack {
                        Label(app.screenPermission ? "屏幕录制已允许" : "允许截取屏幕", systemImage: app.screenPermission ? "checkmark.circle.fill" : "rectangle.dashed")
                        Spacer()
                        if !app.screenPermission {
                            Button("重新检测") { app.refreshPermission() }
                            Button("去系统授权") { app.requestPermission() }.buttonStyle(.borderedProminent)
                        }
                    }
                    if !app.screenPermission {
                        Text("在系统设置中允许 ScreenGPT 录制屏幕后，点击“重新检测”。若仍未生效，请完全退出应用后重新打开。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(account.active?.connected == true ? "ChatGPT 已连接" : "连接你的 ChatGPT", systemImage: account.active?.connected == true ? "checkmark.circle.fill" : "person.crop.circle")
                        Spacer(); Button("账号设置") { page = "account" }
                    }
                }
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("全局快捷键").fontWeight(.medium); Text("点击右侧，再按下你喜欢的组合键。").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    ShortcutRecorder(label: preferences.shortcutLabel) { app.setShortcut(code: $0, modifiers: $1, label: $2) }.frame(width: 145, height: 34)
                }
                Divider()
                HStack { Text("默认翻译"); Spacer(); languagePicker("原文", selection: $preferences.source, auto: true); Image(systemName: "arrow.right").foregroundStyle(.secondary); languagePicker("译文", selection: $preferences.target, auto: false) }
            }
            card {
                HStack { Text("选区外暗度"); Spacer(); Text("\(Int((preferences.dim * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: $preferences.dim, in: 0.1...0.8, step: 0.05).accessibilityLabel("选区外暗度")
                HStack {
                    Text("浮窗风格"); Spacer()
                    Picker("浮窗风格", selection: $preferences.material) { Text("毛玻璃").tag("glass"); Text("简洁").tag("minimal") }.labelsHidden().pickerStyle(.segmented).frame(width: 208)
                }
                HStack {
                    Text("外观"); Spacer()
                    Picker("外观", selection: $preferences.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.labelsHidden().frame(width: 140)
                }
            }
            card {
                Toggle("自动保存完成的回答", isOn: $preferences.automaticallySave).toggleStyle(.switch)
                Text("默认关闭。保存时会将这次选区截图与回答一起保存在本机，随时可在“已保存”中删除。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13))
    }
    private func languagePicker(_ title: String, selection: Binding<Language>, auto: Bool) -> some View {
        Picker(title, selection: selection) { ForEach(Language.allCases.filter { auto || $0 != .auto }) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 105)
    }
    private var accountPage: some View {
        Group {
            heading("连接 ChatGPT", "使用你的账号和可用套餐额度。")
            card {
                if account.needsCredentialAccess {
                    Label("恢复已保存的账号", systemImage: "key.fill").fontWeight(.medium)
                    Text("应用更新后，macOS 可能要求重新确认钥匙串访问。点击下方按钮，在系统提示中允许 ScreenGPT 读取之前保存的登录信息。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("解锁已保存账号") { Task { await account.restoreSavedAccounts() } }.buttonStyle(.borderedProminent).disabled(account.busy)
                }
                if !account.profiles.isEmpty {
                    Picker("账号", selection: Binding(get: { account.activeID }, set: { account.select($0) })) {
                        Text("选择账号").tag("")
                        ForEach(account.profiles) { Text($0.label).tag($0.id) }
                    }.disabled(account.busy)
                }
                if let active = account.active {
                    Label(active.connected ? "套餐已授权" : "需要登录或授权套餐", systemImage: active.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark").foregroundStyle(active.connected ? accent : .secondary)
                }
                HStack {
                    Button("Continue with ChatGPT") { Task { await account.signIn(existingID: account.active?.id) } }
                        .buttonStyle(.borderedProminent).tint(.primary).disabled(account.busy || account.needsCredentialAccess)
                    if account.busy {
                        ProgressView().controlSize(.small)
                        if !account.restoringCredentials { Button("取消") { account.cancelLogin() } }
                    }
                }
                if !account.profiles.isEmpty {
                    HStack {
                        Button("添加其他账号") { Task { await account.signIn() } }.disabled(account.busy)
                        Spacer()
                        if account.active?.accessToken != nil { Button("退出此账号") { Task { await account.signOut() } }.disabled(account.busy) }
                    }
                }
                if let status = account.status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            HStack {
                Text("任务模型").fontWeight(.semibold); Spacer()
                if account.loadingModels { ProgressView().controlSize(.small) }
                Button("刷新模型") { Task { await account.loadModels() } }.disabled(account.loadingModels || account.active?.connected != true)
            }
            modelCard("做题", subtitle: "复杂题目可选择推理能力更强的模型，并提高思考强度。", icon: "sparkles", configuration: $preferences.inference.solve)
            modelCard("翻译", subtitle: "日常翻译可选择响应更快的模型，并降低思考强度。", icon: "character.bubble", configuration: $preferences.inference.translate)
            Text("两项设置分别保存。可选模型由你的账号决定；思考档位随模型支持情况变化，强度越高通常等待越久。").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("每次截图单独处理，不读取其他聊天。登录凭据存入 macOS 钥匙串；只有点击“做题”或“翻译”时，选区图片才会发送至 OpenAI。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            Link("管理 ChatGPT 中的应用授权与用量 ↗", destination: URL(string: "https://chatgpt.com/#settings")!).font(.system(size: 12))
        }.font(.system(size: 13))
    }
    private func modelCard(_ title: String, subtitle: String, icon: String, configuration: Binding<ModelConfiguration>) -> some View {
        let selected = configuration.wrappedValue.model
        let model = selected.isEmpty ? account.models.first : account.models.first(where: { $0.slug == selected })
        let efforts = model?.availableEfforts ?? [.automatic]
        let effort = Binding<ReasoningEffort>(
            get: { model?.validatedEffort(configuration.wrappedValue.effort) ?? .automatic },
            set: { configuration.wrappedValue.effort = $0 }
        )
        return card {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("模型", selection: configuration.model) {
                Text("自动 · 使用账号首选模型").tag("")
                if !selected.isEmpty && model == nil { Text("上次选择 · \(selected)").tag(selected) }
                ForEach(account.models) { Text($0.display_name).tag($0.slug) }
            }.disabled(account.models.isEmpty).accessibilityLabel("\(title)模型")
            Picker("思考强度", selection: effort) {
                ForEach(efforts) { Text($0.title).tag($0) }
            }.disabled(model == nil || efforts.count == 1).accessibilityLabel("\(title)思考强度")
            if !account.models.isEmpty && model == nil {
                Text("此账号当前无法使用上次选择的模型，请重新选择。").font(.system(size: 12)).foregroundStyle(.orange)
            } else if let model, model.availableEfforts.count == 1 {
                Text("该模型暂未提供可确认的思考档位，使用模型默认设置。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let model, selected.isEmpty {
                Text("当前自动选择：\(model.display_name)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var historyPage: some View {
        Group {
            heading("已保存", "只收录你在 ScreenGPT 保存的截图和回答。")
            if let error = history.error { Text(error).foregroundStyle(.orange) }
            if history.entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bookmark").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text("还没有保存的内容").font(.system(size: 15, weight: .medium))
                    Text("遇到值得留下的答案，点一下“保存”。").foregroundStyle(.secondary).font(.system(size: 12))
                }.frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                ForEach(history.entries) { entry in
                    card {
                        HStack { Label(entry.title, systemImage: entry.action.icon).fontWeight(.medium); Spacer(); Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary) }
                        if let image = NSImage(data: entry.image) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 7)) }
                        AnswerText(text: entry.answer)
                        HStack {
                            Button("复制回答") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.answer, forType: .string) }
                            Spacer(); Button("删除", role: .destructive) { history.delete(entry) }
                        }
                    }
                }
            }
        }.font(.system(size: 13))
    }
    private var aboutPage: some View {
        Group {
            heading("ScreenGPT", "把阅读留在眼前，把理解交给 AI。")
            card {
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · macOS 14 或更新版本").fontWeight(.medium)
                Text("按下快捷键冻结屏幕，拖动框选，再选择做题或翻译。结果会自动放在合适的位置，也可以拖动浮窗顶部调整。按 Esc 退出。").lineSpacing(5)
                Button("试用界面预览") { app.beginCapture(preview: true) }
                Text("预览使用内置示例，不截取屏幕，也不消耗套餐额度。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("ScreenGPT 是独立的开源应用，与 OpenAI 无隶属关系。AI 回答可能有误，请结合原文核对。").font(.system(size: 12)).foregroundStyle(.secondary)
            Link("ChatGPT 套餐接入说明 ↗", destination: URL(string: "https://developers.openai.com/siwc/token-sharing-open-source")!)
        }.font(.system(size: 13))
    }
}
