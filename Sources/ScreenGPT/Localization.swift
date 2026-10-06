import Foundation
import ScreenGPTCore

enum AppLocalization {
    static var language: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
    }
}

/// Explicit bilingual strings work in native menus, canvas drawing and SwiftUI.
func L(_ chinese: String, _ english: String) -> String {
    AppLocalization.language.text(chinese, english)
}

extension ReasoningEffort {
    var localizedTitle: String {
        switch self {
        case .automatic: L("自动（模型默认）", "Automatic (model default)")
        case .low: L("轻度", "Low")
        case .medium: L("中度", "Medium")
        case .high: L("高度", "High")
        case .xhigh: L("极高", "Extra high")
        }
    }
}
