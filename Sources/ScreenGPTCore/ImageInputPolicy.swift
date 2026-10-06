public enum ImageInputPolicy {
    private static let originalDetailModels: Set<String> = [
        "gpt-6-astra",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano"
    ]

    /// Selects image detail based on documented model support and image size.
    public static func detail(model: String, pixelWidth: Int, pixelHeight: Int) -> String {
        guard originalDetailModels.contains(model),
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 65_535, pixelHeight <= 65_535 else {
            return "high"
        }

        let widthBlocks = (pixelWidth + 31) / 32
        let heightBlocks = (pixelHeight + 31) / 32
        guard widthBlocks <= 30_000 / heightBlocks else {
            return "high"
        }

        return "original"
    }
}
