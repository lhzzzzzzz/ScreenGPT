import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case low
    case medium
    case high
    case xhigh

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "自动（模型默认）"
        case .low: "轻度"
        case .medium: "中度"
        case .high: "高度"
        case .xhigh: "极高"
        }
    }
}

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var model: String
    public var effort: ReasoningEffort

    public init(model: String = "", effort: ReasoningEffort = .automatic) {
        self.model = model
        self.effort = effort
    }

    private enum CodingKeys: String, CodingKey { case model, effort }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? container.decode(String.self, forKey: .model)) ?? ""
        let rawEffort = (try? container.decode(String.self, forKey: .effort)) ?? ""
        effort = ReasoningEffort(rawValue: rawEffort) ?? .automatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
    }
}

public struct InferencePreferences: Codable, Equatable, Sendable {
    public var solve: ModelConfiguration
    public var translate: ModelConfiguration

    public init(legacyModel: String = "") {
        solve = ModelConfiguration(model: legacyModel)
        translate = ModelConfiguration(model: legacyModel)
    }

    public init(solve: ModelConfiguration, translate: ModelConfiguration) {
        self.solve = solve
        self.translate = translate
    }
}

public struct ModelChoice: Decodable, Identifiable, Sendable {
    public let slug: String
    public let display_name: String
    public let visibility: String?

    public var id: String { slug }

    /// Official model documentation for the fallback capability list:
    /// https://developers.openai.com/api/docs/guides/reasoning
    /// https://developers.openai.com/api/docs/models/gpt-6-astra
    /// https://developers.openai.com/api/docs/models/gpt-6.1-sol
    /// https://developers.openai.com/api/docs/models/gpt-6-sol
    /// https://developers.openai.com/api/docs/models/gpt-6-luna
    /// https://developers.openai.com/api/docs/models/gpt-5.6-sol
    /// https://developers.openai.com/api/docs/models/gpt-5.6-terra
    /// https://developers.openai.com/api/docs/models/gpt-5.6-luna
    /// https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.5
    private static let documentedEffortModels: Set<String> = [
        "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"
    ]

    private enum CodingKeys: String, CodingKey {
        case slug, display_name, visibility
        case supported_reasoning_levels, supported_reasoning_efforts
    }

    private struct EffortDescription: Decodable {
        let effort: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        display_name = try container.decode(String.self, forKey: .display_name)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)

        // A supplied capability field is authoritative, including an empty list.
        if container.contains(.supported_reasoning_levels) {
            availableEfforts = Self.decodeEfforts(from: container, key: .supported_reasoning_levels)
        } else if container.contains(.supported_reasoning_efforts) {
            availableEfforts = Self.decodeEfforts(from: container, key: .supported_reasoning_efforts)
        } else if Self.documentedEffortModels.contains(slug) {
            availableEfforts = [.automatic, .low, .medium, .high, .xhigh]
        } else {
            availableEfforts = [.automatic]
        }
    }

    public let availableEfforts: [ReasoningEffort]

    public func validatedEffort(_ preference: ReasoningEffort) -> ReasoningEffort {
        availableEfforts.contains(preference) ? preference : .automatic
    }

    public func reasoningParameters(_ preference: ReasoningEffort) -> [String: String]? {
        let validated = validatedEffort(preference)
        guard validated != .automatic else { return nil }
        return ["effort": validated.rawValue]
    }

    private static func decodeEfforts(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [ReasoningEffort] {
        let values: [String]
        if let strings = try? container.decode([String].self, forKey: key) {
            values = strings
        } else if let entries = try? container.decode([EffortDescription].self, forKey: key) {
            values = entries.compactMap(\.effort)
        } else {
            values = []
        }

        var seen = Set<ReasoningEffort>()
        let decoded = values.compactMap { ReasoningEffort(rawValue: $0) }
            .filter { $0 != .automatic && seen.insert($0).inserted }
        return [.automatic] + decoded
    }
}
