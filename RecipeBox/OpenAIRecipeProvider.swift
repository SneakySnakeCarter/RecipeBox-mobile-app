import Foundation

/// Sends OCR'd recipe text (not the photo) to OpenAI's chat completions
/// API. Requires an OpenAI API key from
/// https://platform.openai.com/api-keys.
///
/// Cost notes: text-only input plus the "mini" model tier — structuring
/// already-extracted text doesn't need the flagship model. Check current
/// pricing/model names at https://platform.openai.com/docs/pricing
/// before changing `model`, since both can move over time.
struct OpenAIRecipeProvider: AIRecipeProvider {
    let displayName = "ChatGPT (OpenAI)"
    let apiKeyStorageKey = "apiKey.openai"
    let apiKeyHelpURL = URL(string: "https://platform.openai.com/api-keys")

    private let model = "gpt-4o-mini"

    /// A bit above the minimum needed for a simple recipe, as headroom
    /// for the richer schema (grouped ingredients, tips, nutrition) —
    /// still capped, since this directly bounds worst-case cost per request.
    private let maxTokens = 900

    func requestRecipe(
        fromOCRText ocrText: String,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(AIProviderError.missingAPIKey))
            return
        }
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(AIProviderError.emptyOCRText))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            "messages": [[
                "role": "user",
                "content": AIRecipePrompt.instructions + "\n" + ocrText
            ]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(AIProviderError.emptyResponse))
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                if let errorObj = json?["error"] as? [String: Any],
                   let message = errorObj["message"] as? String {
                    completion(.failure(AIProviderError.badResponse(message)))
                    return
                }

                guard let choices = json?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String else {
                    completion(.failure(AIProviderError.emptyResponse))
                    return
                }

                let recipe = try AIRecipeJSONParser.parse(text)
                completion(.success(recipe))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
