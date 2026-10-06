import Testing
@testable import ScreenGPTCore

@Test func documentedModelsUseOriginalForSupportedImageDimensions() {
    let models = [
        "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano"
    ]

    for model in models {
        #expect(ImageInputPolicy.detail(model: model, pixelWidth: 1920, pixelHeight: 1080) == "original")
    }
}

@Test func unsupportedAndUnknownModelsUseHigh() {
    for model in ["gpt-5.2", "gpt-4.1-mini", "unknown", "gpt-6-astra-preview", "gpt-5.4-mini-2026-01-01"] {
        #expect(ImageInputPolicy.detail(model: model, pixelWidth: 1920, pixelHeight: 1080) == "high")
    }
}

@Test func blockBudgetAllowsExactlyThirtyThousandBlocks() {
    #expect(ImageInputPolicy.detail(model: "gpt-5.4", pixelWidth: 32 * 150, pixelHeight: 32 * 200) == "original")
}

@Test func blockBudgetFallsBackJustAboveThirtyThousandBlocks() {
    #expect(ImageInputPolicy.detail(model: "gpt-5.4", pixelWidth: 32 * 151, pixelHeight: 32 * 200) == "high")
}

@Test func invalidOrOversizedDimensionsFallBackSafely() {
    let model = "gpt-6-astra"
    for (width, height) in [(0, 32), (-1, 32), (32, 0), (32, -1), (65_536, 32), (32, 65_536), (Int.max, 32), (32, Int.max)] {
        #expect(ImageInputPolicy.detail(model: model, pixelWidth: width, pixelHeight: height) == "high")
    }
}
