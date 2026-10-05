import AppKit
import SwiftUI
import ScreenGPTCore

enum CaptureAction: String, Codable { case solve, translate
    var title: String { self == .solve ? "做题" : "翻译" }
    var icon: String { self == .solve ? "sparkles" : "character.bubble" }
}
enum Language: String, Codable, CaseIterable, Identifiable {
    case english, chinese, japanese, korean, french, german, spanish, auto
    var id: String { rawValue }
    var title: String { switch self {
        case .english: return "英语"; case .chinese: return "中文"; case .japanese: return "日语"
        case .korean: return "韩语"; case .french: return "法语"; case .german: return "德语"
        case .spanish: return "西班牙语"; case .auto: return "自动识别"
    } }
    var short: String { switch self {
        case .english: return "英"; case .chinese: return "中"; case .japanese: return "日"
        case .korean: return "韩"; case .french: return "法"; case .german: return "德"
        case .spanish: return "西"; case .auto: return "自动"
    } }
}
struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
@MainActor final class Preferences: ObservableObject {
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
        action == .solve ? inference.solve : inference.translate
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
    var title: String { action == .translate ? "\(source.title) → \(target.title)" : "题目解答" }
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
        } catch { self.error = "无法读取本地历史记录。" }
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
        catch { self.error = "删除失败，请稍后重试。" }
    }
}
