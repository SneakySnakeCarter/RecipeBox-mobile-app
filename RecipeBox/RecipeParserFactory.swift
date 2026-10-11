import Foundation

/// The set of parsing engines the user can pick from in Settings.
/// To add a new AI provider later: create a type conforming to
/// AIRecipeProvider, then add one case here and one line in
/// RecipeParserFactory.makeParser() below. Nothing else in the app changes.
enum ParserEngine: String, CaseIterable, Identifiable {
    case claude
    case openAI
    case onDevice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return AnthropicRecipeProvider().displayName
        case .openAI: return OpenAIRecipeProvider().displayName
        case .onDevice: return "On-Device (Fallback, Offline)"
        }
    }

    var isAI: Bool { self != .onDevice }

    /// The underlying provider for AI engines, nil for on-device.
    var aiProvider: AIRecipeProvider? {
        switch self {
        case .onDevice: return nil
        case .claude: return AnthropicRecipeProvider()
        case .openAI: return OpenAIRecipeProvider()
        }
    }
}

enum ParserSettingsKeys {
    static let selectedEngine = "parserEngine.selected"
}

enum RecipeParserFactory {
    /// Builds whichever parser is currently selected in Settings.
    /// Called fresh each time a photo is parsed, so changing the engine
    /// (or updating an API key) takes effect immediately — no restart needed.
    static func makeParser() -> RecipeParsing {
        let rawValue = UserDefaults.standard.string(forKey: ParserSettingsKeys.selectedEngine)
        let engine = ParserEngine(rawValue: rawValue ?? "") ?? .claude

        guard let provider = engine.aiProvider else {
            return VisionRecipeParser()
        }
        let apiKey = KeychainHelper.shared.read(forKey: provider.apiKeyStorageKey) ?? ""
        return AIRecipeParser(provider: provider, apiKey: apiKey)
    }
}
