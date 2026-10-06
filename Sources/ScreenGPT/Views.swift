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
                navigation("general", L("通用", "General"), "slider.horizontal.3")
                navigation("account", L("ChatGPT 账号", "ChatGPT account"), "person.crop.circle")
                navigation("history", L("已保存", "Saved"), "clock")
                navigation("about", L("关于", "About"), "info.circle")
                Spacer()
                Button { app.beginCapture() } label: {
                    HStack { Image(systemName: "viewfinder"); Text(L("开始框选", "Start selecting")); Spacer() }.padding(10)
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
                            Button { app.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("关闭提示", "Dismiss message"))
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
        .environment(\.locale, preferences.interfaceLanguage.locale)
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
            heading(L("看见，即可提问。", "See it. Ask about it."), L("一个快捷键，把屏幕上的内容变成答案。", "Turn screen content into answers with one shortcut."))
            card {
                HStack {
                    Text(L("界面语言", "Interface language")); Spacer()
                    Picker(L("界面语言", "Interface language"), selection: $preferences.interfaceLanguage) {
                        Text("简体中文").tag(InterfaceLanguage.chinese)
                        Text("English").tag(InterfaceLanguage.english)
                    }.labelsHidden().frame(width: 150)
                }
            }
            if !app.screenPermission || account.active?.connected != true {
                card {
                    Text(L("准备好就开始", "Ready when you are")).font(.system(size: 14, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Label(app.screenPermission ? L("屏幕录制已允许", "Screen recording allowed") : L("允许截取屏幕", "Allow screen capture"), systemImage: app.screenPermission ? "checkmark.circle.fill" : "rectangle.dashed")
                            Spacer()
                            if !app.screenPermission {
                                Button(L("重新检测", "Check again")) { app.refreshPermission() }
                                Button(L("去系统授权", "Open System Settings")) { app.requestPermission() }.buttonStyle(.borderedProminent)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label(app.screenPermission ? L("屏幕录制已允许", "Screen recording allowed") : L("允许截取屏幕", "Allow screen capture"), systemImage: app.screenPermission ? "checkmark.circle.fill" : "rectangle.dashed")
                            if !app.screenPermission {
                                HStack {
                                    Button(L("重新检测", "Check again")) { app.refreshPermission() }
                                    Button(L("去系统授权", "Open System Settings")) { app.requestPermission() }.buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    if !app.screenPermission {
                        Text(L("在系统设置中允许 ScreenGPT 录制屏幕后，点击“重新检测”。若仍未生效，请完全退出应用后重新打开。", "Allow ScreenGPT to record the screen in System Settings, then click “Check again.” If it still does not work, quit ScreenGPT completely and reopen it.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label(account.active?.connected == true ? L("ChatGPT 已连接", "ChatGPT connected") : L("连接你的 ChatGPT", "Connect ChatGPT"), systemImage: account.active?.connected == true ? "checkmark.circle.fill" : "person.crop.circle")
                        Spacer(); Button(L("账号设置", "Account settings")) { page = "account" }
                    }
                }
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(L("全局快捷键", "Global shortcut")).fontWeight(.medium); Text(L("点击右侧，再按下你喜欢的组合键。", "Click the field, then press your preferred key combination.")).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    ShortcutRecorder(label: preferences.shortcutLabel) { app.setShortcut(code: $0, modifiers: $1, label: $2) }.frame(width: 145, height: 34)
                }
                Divider()
                HStack { Text(L("默认翻译", "Default translation")); Spacer(); languagePicker(L("原文", "Source"), selection: $preferences.source, auto: true); Image(systemName: "arrow.right").foregroundStyle(.secondary); languagePicker(L("译文", "Translate to"), selection: $preferences.target, auto: false) }
            }
            card {
                HStack { Text(L("选区外暗度", "Outside selection dimming")); Spacer(); Text("\(Int((preferences.dim * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: $preferences.dim, in: 0.1...0.8, step: 0.05).accessibilityLabel(L("选区外暗度", "Outside selection dimming"))
                HStack {
                    Text(L("浮窗风格", "Floating window style")); Spacer()
                    Picker(L("浮窗风格", "Floating window style"), selection: $preferences.material) { Text(L("毛玻璃", "Frosted glass")).tag("glass"); Text(L("简洁", "Minimal")).tag("minimal") }.labelsHidden().pickerStyle(.segmented).frame(width: 208)
                }
                HStack {
                    Text(L("外观", "Appearance")); Spacer()
                    Picker(L("外观", "Appearance"), selection: $preferences.appearance) { Text(L("跟随系统", "System")).tag("system"); Text(L("浅色", "Light")).tag("light"); Text(L("深色", "Dark")).tag("dark") }.labelsHidden().frame(width: 140)
                }
            }
            card {
                Toggle(L("自动保存完成的回答", "Automatically save completed answers"), isOn: $preferences.automaticallySave).toggleStyle(.switch)
                Text(L("默认关闭。保存时会将这次选区截图与回答一起保存在本机，随时可在“已保存”中删除。", "Off by default. Saved screenshots and answers stay on this Mac and can be deleted from Saved.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13))
    }
    private func languagePicker(_ title: String, selection: Binding<Language>, auto: Bool) -> some View {
        Picker(title, selection: selection) { ForEach(Language.allCases.filter { auto || $0 != .auto }) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 105).id(preferences.interfaceLanguage)
    }
    private var accountPage: some View {
        Group {
            heading(L("连接 ChatGPT", "Connect ChatGPT"), L("使用你的账号和可用套餐额度。", "Use your account and available plan access."))
            card {
                if account.needsCredentialAccess {
                    Label(L("恢复已保存的账号", "Restore saved account"), systemImage: "key.fill").fontWeight(.medium)
                    Text(L("应用更新后，macOS 可能要求重新确认钥匙串访问。点击下方按钮，在系统提示中允许 ScreenGPT 读取之前保存的登录信息。", "After an app update, macOS may ask you to confirm Keychain access again. Click below and allow ScreenGPT to read your saved sign-in details.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("解锁已保存账号", "Unlock saved account")) { Task { await account.restoreSavedAccounts() } }.buttonStyle(.borderedProminent).disabled(account.busy)
                }
                if !account.profiles.isEmpty {
                    Picker(L("账号", "Account"), selection: Binding(get: { account.activeID }, set: { account.select($0) })) {
                        Text(L("选择账号", "Choose an account")).tag("")
                        ForEach(account.profiles) { Text($0.label).tag($0.id) }
                    }.disabled(account.busy).id(preferences.interfaceLanguage)
                }
                if let active = account.active {
                    Label(active.connected ? L("套餐已授权", "Plan access authorized") : L("需要登录或授权套餐", "Sign in or authorize plan access"), systemImage: active.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark").foregroundStyle(active.connected ? accent : .secondary)
                }
                HStack {
                    Button("Continue with ChatGPT") { Task { await account.signIn(existingID: account.active?.id) } }
                        .buttonStyle(.borderedProminent).tint(.primary).disabled(account.busy || account.needsCredentialAccess)
                    if account.busy {
                        ProgressView().controlSize(.small)
                        if !account.restoringCredentials { Button(L("取消", "Cancel")) { account.cancelLogin() } }
                    }
                }
                if !account.profiles.isEmpty {
                    HStack {
                        Button(L("添加其他账号", "Add another account")) { Task { await account.signIn() } }.disabled(account.busy)
                        Spacer()
                        if account.active?.accessToken != nil { Button(L("退出此账号", "Sign out")) { Task { await account.signOut() } }.disabled(account.busy) }
                    }
                }
                if let status = account.status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            HStack {
                Text(L("任务模型", "Task models")).fontWeight(.semibold); Spacer()
                if account.loadingModels { ProgressView().controlSize(.small) }
                Button(L("刷新模型", "Refresh models")) { Task { await account.loadModels() } }.disabled(account.loadingModels || account.active?.connected != true)
            }
            modelCard(L("做题", "Solve"), subtitle: L("复杂题目可选择推理能力更强的模型，并提高思考强度。", "For complex problems, choose a stronger reasoning model and higher effort."), icon: "sparkles", configuration: $preferences.inference.solve)
            modelCard(L("翻译", "Translate"), subtitle: L("日常翻译可选择响应更快的模型，并降低思考强度。", "For everyday translation, choose a faster model and lower effort."), icon: "character.bubble", configuration: $preferences.inference.translate)
            modelCard(L("问答", "Questions"), subtitle: L("从“提问”开始时使用此设置；后续问题沿用起始任务的模型与思考强度。", "Used when starting with Ask; follow-ups keep the starting task's model and effort."), icon: "bubble.left.and.bubble.right", configuration: $preferences.inference.ask)
            Text(L("三项任务的模型与思考强度分别保存。可选模型由你的账号决定；思考档位随模型支持情况变化，强度越高通常等待越久。", "Model and reasoning effort are saved separately for each task. Available models depend on your account; higher effort usually takes longer.")).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L("每张截图单独处理，不读取其他聊天。登录凭据存入 macOS 钥匙串。只有点击“做题”或“翻译”时才会上传选区图片；问答仅在发送时上传输入、图片和当前会话的后续问题。重新框选会清除旧回答和后续问题。", "Each screenshot is processed separately; other chats are not read. Sign-in details stay in macOS Keychain. The selected image is sent only when you choose Solve or Translate. For Questions, the input and image are sent only when you submit; follow-ups use the current session. A new selection clears the previous answer and follow-up context.")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            Link(L("管理 ChatGPT 中的应用授权与用量 ↗", "Manage ChatGPT app access and usage ↗"), destination: URL(string: "https://chatgpt.com/#settings")!).font(.system(size: 12))
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
            Picker(L("模型", "Model"), selection: configuration.model) {
                Text(L("自动 · 使用账号首选模型", "Automatic · Use account's preferred model")).tag("")
                if !selected.isEmpty && model == nil { Text(L("上次选择 · \(selected)", "Previous selection · \(selected)")).tag(selected) }
                ForEach(account.models) { Text($0.display_name).tag($0.slug) }
            }.disabled(account.models.isEmpty).accessibilityLabel(L("\(title)模型", "\(title) model")).id(preferences.interfaceLanguage)
            Picker(L("思考强度", "Reasoning effort"), selection: effort) {
                ForEach(efforts) { Text($0.localizedTitle).tag($0) }
            }.disabled(model == nil || efforts.count == 1).accessibilityLabel(L("\(title)思考强度", "\(title) reasoning effort")).id(preferences.interfaceLanguage)
            if !account.models.isEmpty && model == nil {
                Text(L("此账号当前无法使用上次选择的模型，请重新选择。", "This account cannot use the previously selected model. Choose another model.")).font(.system(size: 12)).foregroundStyle(.orange)
            } else if let model, model.availableEfforts.count == 1 {
                Text(L("该模型暂未提供可确认的思考档位，使用模型默认设置。", "No reasoning effort options are available for this model; its default will be used.")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let model, selected.isEmpty {
                Text(L("当前自动选择：\(model.display_name)", "Currently selected automatically: \(model.display_name)")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var historyPage: some View {
        Group {
            heading(L("已保存", "Saved"), L("只收录你在 ScreenGPT 保存的截图和回答。", "Only screenshots and answers saved in ScreenGPT appear here."))
            if let error = history.error { Text(error).foregroundStyle(.orange) }
            if history.entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bookmark").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(L("还没有保存的内容", "Nothing saved yet")).font(.system(size: 15, weight: .medium))
                    Text(L("遇到值得留下的答案，点一下“保存”。", "Save an answer whenever you want to keep it.")).foregroundStyle(.secondary).font(.system(size: 12))
                }.frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                ForEach(history.entries) { entry in
                    card {
                        HStack { Label(entry.title, systemImage: entry.action.icon).fontWeight(.medium); Spacer(); Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(preferences.interfaceLanguage.locale))).font(.system(size: 11)).foregroundStyle(.secondary) }
                        if let image = NSImage(data: entry.image) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 7)) }
                        AnswerText(text: entry.answer)
                        HStack {
                            Button(L("复制回答", "Copy answer")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.answer, forType: .string) }
                            Spacer(); Button(L("删除", "Delete"), role: .destructive) { history.delete(entry) }
                        }
                    }
                }
            }
        }.font(.system(size: 13))
    }
    private var aboutPage: some View {
        Group {
            heading("ScreenGPT", L("把阅读留在眼前，把理解交给 AI。", "Keep reading on screen; let AI help you understand."))
            card {
                Text(L("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · macOS 14 或更新版本", "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development") · macOS 14 or later")).fontWeight(.medium)
                Text(L("按下快捷键冻结屏幕，拖动框选，再选择做题、翻译或提问。选好后拖动内部移动选区，拖动边缘或角点调整大小；点“重新框选”才能重画。重新框选会清除旧回答和后续问题。结果会自动放在合适的位置，也可以拖动浮窗顶部调整。按 Esc 退出。", "Press the shortcut to freeze the screen, drag to select an area, then choose Solve, Translate, or Ask. Drag inside the selection to move it, or drag an edge or corner to resize it. Choose “Reselect” to draw a new area; this clears the previous answer and follow-up context. Results appear in a suitable position, and you can drag the top of the window to move it. Press Esc to exit.")).lineSpacing(5)
                Button(L("试用界面预览", "Try the preview")) { app.beginCapture(preview: true) }
                Text(L("预览使用内置示例，不截取屏幕，也不消耗套餐额度。", "The preview uses a built-in example. It does not capture your screen or use plan access.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(L("ScreenGPT 是独立的开源应用，与 OpenAI 无隶属关系。AI 回答可能有误，请结合原文核对。", "ScreenGPT is an independent open-source app and is not affiliated with OpenAI. AI answers may be wrong; check them against the source.")).font(.system(size: 12)).foregroundStyle(.secondary)
            Link(L("ChatGPT 套餐接入说明 ↗", "ChatGPT plan access details ↗"), destination: URL(string: "https://developers.openai.com/siwc/token-sharing-open-source")!)
        }.font(.system(size: 13))
    }
}
