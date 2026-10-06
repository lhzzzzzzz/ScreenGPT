import Foundation

public enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"
    public var id: String { rawValue }
    public var title: String { self == .chinese ? "简体中文" : "English" }
    public var locale: Locale { Locale(identifier: rawValue) }
    public func text(_ chinese: String, _ english: String) -> String { self == .chinese ? chinese : english }
}
