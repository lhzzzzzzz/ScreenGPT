import Foundation
import Testing
@testable import ScreenGPTCore

@Test func solveTranslateAndAskConfigurationsAreIndependentAndCodable() throws {
    var preferences = InferencePreferences(legacyModel: "gpt-6-astra")
    preferences.solve.effort = .high
    preferences.translate.model = "gpt-6-luna"
    preferences.translate.effort = .low
    preferences.ask.model = "gpt-6-sol"
    preferences.ask.effort = .medium

    #expect(preferences.solve.model == "gpt-6-astra")
    #expect(preferences.solve.effort == .high)
    #expect(preferences.translate.model == "gpt-6-luna")
    #expect(preferences.translate.effort == .low)
    #expect(preferences.ask.model == "gpt-6-sol")
    #expect(preferences.ask.effort == .medium)

    let encoded = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(InferencePreferences.self, from: encoded)
    #expect(decoded == preferences)
}

@Test func legacyModelMigratesToBothPurposesWithAutomaticEffort() {
    let preferences = InferencePreferences(legacyModel: "legacy-model")
    #expect(preferences.solve == ModelConfiguration(model: "legacy-model"))
    #expect(preferences.translate == ModelConfiguration(model: "legacy-model"))
    #expect(preferences.ask == ModelConfiguration(model: "legacy-model"))
}

@Test func olderTwoPurposeJSONPreservesChoicesAndDefaultsAskToSolve() throws {
    let json = #"{"solve":{"model":"solve-model","effort":"high"},"translate":{"model":"translate-model","effort":"low"}}"#
    let preferences = try JSONDecoder().decode(InferencePreferences.self, from: Data(json.utf8))

    #expect(preferences.solve == ModelConfiguration(model: "solve-model", effort: .high))
    #expect(preferences.translate == ModelConfiguration(model: "translate-model", effort: .low))
    #expect(preferences.ask == preferences.solve)
}

@Test func explicitThreePurposeConfigurationsRemainDistinct() throws {
    let preferences = InferencePreferences(
        solve: ModelConfiguration(model: "solve-model", effort: .high),
        translate: ModelConfiguration(model: "translate-model", effort: .low),
        ask: ModelConfiguration(model: "ask-model", effort: .medium)
    )
    let encoded = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(InferencePreferences.self, from: encoded)

    #expect(decoded.solve == ModelConfiguration(model: "solve-model", effort: .high))
    #expect(decoded.translate == ModelConfiguration(model: "translate-model", effort: .low))
    #expect(decoded.ask == ModelConfiguration(model: "ask-model", effort: .medium))
}

@Test func missingAndUnknownEffortDecodeAsAutomaticAndPreserveModel() throws {
    let decoder = JSONDecoder()
    let missing = try decoder.decode(ModelConfiguration.self, from: Data(#"{"model":"kept-model"}"#.utf8))
    let unknown = try decoder.decode(ModelConfiguration.self, from: Data(#"{"model":"also-kept","effort":"future-level"}"#.utf8))

    #expect(missing.model == "kept-model")
    #expect(missing.effort == .automatic)
    #expect(unknown.model == "also-kept")
    #expect(unknown.effort == .automatic)
}

@Test func advertisedNarrowerSupportOverridesDocumentedFallbackAndValidatesRequests() throws {
    let choice = try decodeChoice(#"{"slug":"gpt-6-astra","display_name":"Astra","visibility":"public","supported_reasoning_levels":["low","medium"]}"#)

    #expect(choice.availableEfforts == [.automatic, .low, .medium])
    #expect(choice.validatedEffort(.high) == .automatic)
    #expect(choice.reasoningParameters(.high) == nil)
    #expect(choice.reasoningParameters(.low) == ["effort": "low"])
}

@Test func explicitlyEmptyAdvertisedSupportAllowsOnlyAutomatic() throws {
    let choice = try decodeChoice(#"{"slug":"gpt-6-astra","display_name":"Astra","visibility":"public","supported_reasoning_efforts":[]}"#)

    #expect(choice.availableEfforts == [.automatic])
    #expect(choice.validatedEffort(.xhigh) == .automatic)
    #expect(choice.reasoningParameters(.xhigh) == nil)
}

@Test func unknownModelFallsBackToAutomaticOnlyWithoutGuessing() throws {
    let choice = try decodeChoice(#"{"slug":"gpt-6-astra-preview","display_name":"Preview","visibility":"public"}"#)

    #expect(choice.availableEfforts == [.automatic])
    #expect(choice.validatedEffort(.medium) == .automatic)
    #expect(choice.reasoningParameters(.medium) == nil)
}

@Test func unknownAdvertisedEffortsAreIgnored() throws {
    let choice = try decodeChoice(#"{"slug":"custom-model","display_name":"Custom","visibility":"public","supported_reasoning_levels":["experimental","medium","max","medium"]}"#)

    #expect(choice.availableEfforts == [.automatic, .medium])
}

@Test func bothAdvertisedMetadataFormatsAreDecoded() throws {
    let strings = try decodeChoice(#"{"slug":"custom-a","display_name":"A","visibility":"public","supported_reasoning_levels":["xhigh","low"]}"#)
    let objects = try decodeChoice(#"{"slug":"custom-b","display_name":"B","visibility":"public","supported_reasoning_efforts":[{"effort":"high","description":"High"},{"effort":"low","description":"Low"}]}"#)

    #expect(strings.availableEfforts == [.automatic, .xhigh, .low])
    #expect(objects.availableEfforts == [.automatic, .high, .low])
}

@Test func documentedFallbackIsExactAndIncludesOnlyConfigurableEfforts() throws {
    let choice = try decodeChoice(#"{"slug":"gpt-5.5","display_name":"5.5","visibility":"public"}"#)
    #expect(choice.availableEfforts == [.automatic, .low, .medium, .high, .xhigh])
    #expect(ReasoningEffort.allCases.map(\.id) == ["auto", "low", "medium", "high", "xhigh"])
    #expect(ReasoningEffort.allCases.map(\.title) == ["自动（模型默认）", "轻度", "中度", "高度", "极高"])
}

private func decodeChoice(_ json: String) throws -> ModelChoice {
    try JSONDecoder().decode(ModelChoice.self, from: Data(json.utf8))
}

@Test func missingVisibilityDoesNotBreakCatalogDecoding() throws {
    let choices = try JSONDecoder().decode([ModelChoice].self, from: Data(#"[{"slug":"hidden","display_name":"Hidden"},{"slug":"gpt-5.6-luna","display_name":"Luna","visibility":"list"}]"#.utf8))
    #expect(choices.filter { $0.visibility == "list" }.map(\.slug) == ["gpt-5.6-luna"])
}
