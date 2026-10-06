import AppKit
import SwiftUI
import ScreenGPTCore

enum CaptureAction: String, Codable { case solve, translate, ask
    var title: String { switch self {
        case .solve: L("做题", "Solve"); case .translate: L("翻译", "Translate"); case .ask: L("提问", "Ask")
    } }
    var resultTitle: String { switch self {
        case .solve: L("题目解答", "Solution"); case .translate: L("译文", "Translation"); case .ask: L("截图问答", "Ask about this")
    } }
    var icon: String { switch self {
        case .solve: "sparkles"; case .translate: "character.bubble"; case .ask: "bubble.left.and.bubble.right"
    } }
}
enum Language: String, Codable, CaseIterable, Identifiable {
    case english, chinese, japanese, korean, french, german, spanish, auto
    var id: String { rawValue }
    var title: String { switch self {
        case .english: return L("英语", "English"); case .chinese: return L("中文", "Chinese"); case .japanese: return L("日语", "Japanese")
        case .korean: return L("韩语", "Korean"); case .french: return L("法语", "French"); case .german: return L("德语", "German")
        case .spanish: return L("西班牙语", "Spanish"); case .auto: return L("自动识别", "Detect language")
    } }
    var short: String { switch self {
        case .english: return L("英", "EN"); case .chinese: return L("中", "ZH"); case .japanese: return L("日", "JA")
        case .korean: return L("韩", "KO"); case .french: return L("法", "FR"); case .german: return L("德", "DE")
        case .spanish: return L("西", "ES"); case .auto: return L("自动", "Auto")
    } }
    // Prompt names are independent of the interface language.
    var promptName: String { switch self {
        case .english: "English"; case .chinese: "Simplified Chinese"; case .japanese: "Japanese"
        case .korean: "Korean"; case .french: "French"; case .german: "German"
        case .spanish: "Spanish"; case .auto: "automatically detected (possibly multilingual)"
    } }
}
struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
@MainActor final class Preferences: ObservableObject {
    @Published var interfaceLanguage: InterfaceLanguage { didSet { defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage") } }
    @Published var dim: Double { didSet { defaults.set(dim, forKey: "dim") } }
    @Published var source: Language { didSet { defaults.set(source.rawValue, forKey: "source") } }
    @Published var target: Language { didSet { defaults.set(target.rawValue, forKey: "target") } }
    @Published var automaticallySave: Bool { didSet { defaults.set(automaticallySave, forKey: "autoSave") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance"); applyAppearance() } }
    @Published var material: String { didSet { defaults.set(material, forKey: "material") } }
    @Published var inference: InferencePreferences { didSet {
        if let data = try? JSONEncoder().encode(inference) { defaults.set(data, forKey: "inferencePreferences") }
    } }
    @Published var shortcutCode: UInt32 { didSet { defaults.set(Int(shortcutCode), forKey: "shortcutCode") } }
    @Published var shortcutModifiers: UInt32 { didSet { defaults.set(Int(shortcutModifiers), forKey: "shortcutModifiers") } }
    @Published var shortcutLabel: String { didSet { defaults.set(shortcutLabel, forKey: "shortcutLabel") } }
    private let defaults = UserDefaults.standard
    init() {
        let d = UserDefaults.standard
        interfaceLanguage = InterfaceLanguage(rawValue: d.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
        dim = d.object(forKey: "dim") as? Double ?? 0.35
        source = Language(rawValue: d.string(forKey: "source") ?? "") ?? .english
        target = Language(rawValue: d.string(forKey: "target") ?? "") ?? .chinese
        automaticallySave = d.bool(forKey: "autoSave")
        appearance = d.string(forKey: "appearance") ?? "system"
        material = d.string(forKey: "material") ?? "glass"
        if let data = d.data(forKey: "inferencePreferences"), let saved = try? JSONDecoder().decode(InferencePreferences.self, from: data) {
            inference = saved
        } else {
            inference = InferencePreferences(legacyModel: d.string(forKey: "model") ?? "")
        }
        shortcutCode = UInt32(d.object(forKey: "shortcutCode") as? Int ?? 2)
        shortcutModifiers = UInt32(d.object(forKey: "shortcutModifiers") as? Int ?? 768)
        shortcutLabel = d.string(forKey: "shortcutLabel") ?? "⇧⌘D"
    }
    func applyAppearance() {
        NSApp.appearance = appearance == "light" ? NSAppearance(named: .aqua) : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    func configuration(for action: CaptureAction) -> ModelConfiguration {
        switch action { case .solve: inference.solve; case .translate: inference.translate; case .ask: inference.ask }
    }
}
struct HistoryEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    let action: CaptureAction
    let source: Language
    let target: Language
    let answer: String
    let image: Data
    var title: String { action == .translate ? "\(source.title) → \(target.title)" : action.resultTitle }
}
@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var error: String?
    private let directory: URL
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenGPT/History", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
            }
        } catch { self.error = L("无法读取本地历史记录。", "Could not read saved history.") }
    }
    func save(_ entry: HistoryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(entry.id.uuidString + ".json")
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries.removeAll { $0.id == entry.id }; entries.insert(entry, at: 0)
    }
    func delete(_ entry: HistoryEntry) {
        do { try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.id.uuidString + ".json")); entries.removeAll { $0.id == entry.id } }
        catch { self.error = L("删除失败，请稍后重试。", "Could not delete this item. Please try again.") }
    }
}
