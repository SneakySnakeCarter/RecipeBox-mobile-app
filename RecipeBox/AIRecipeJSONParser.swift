import Foundation

/// AI models sometimes wrap JSON in markdown fences or add stray text
/// despite instructions not to. This pulls out the JSON object and
/// decodes it into a StructuredRecipe.
enum AIRecipeJSONParser {
    static func parse(_ rawText: String) throws -> StructuredRecipe {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            throw AIProviderError.badResponse("Response didn't contain JSON.")
        }
        let jsonSubstring = text[start...end]
        let data = Data(jsonSubstring.utf8)

        return try JSONDecoder().decode(StructuredRecipe.self, from: data)
    }
}
