import Foundation

/// Sends OCR'd recipe text (not the photo) to Claude and asks it to
/// return structured JSON. Requires an Anthropic API key from
/// https://console.anthropic.com/settings/keys.
///
/// Cost notes: this only sends text, not an image, and uses Claude's
/// cheapest current model tier (Haiku) — structuring already-extracted
/// text into JSON doesn't need a frontier model. If you see accuracy
/// issues on tricky recipes, bumping `model` to a Sonnet-tier model is a
/// one-line change; check current pricing/model IDs at
/// https://docs.claude.com/en/docs/about-claude/models and
/// https://www.anthropic.com/pricing before changing it, since both can
/// move over time.
struct AnthropicRecipeProvider: AIRecipeProvider {
    let displayName = "Claude (Anthropic)"
    let apiKeyStorageKey = "apiKey.anthropic"
    let apiKeyHelpURL = URL(string: "https://console.anthropic.com/settings/keys")

    private let model = "claude-haiku-4-5-20251001"

    /// Structuring a recipe rarely needs more than a few hundred tokens
    /// of output, even with the richer schema (grouped ingredients, tips,
    /// nutrition) — this is set a bit above that as headroom, not raised
    /// freely, since it directly caps worst-case cost per request.
    private let maxTokens = 900

    func requestRecipe(
        fromOCRText ocrText: String,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    ) {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(AIProviderError.emptyOCRText))
            return
        }
        send(
            content: AIRecipePrompt.instructions + "\n" + ocrText,
            maxTokens: maxTokens,
            apiKey: apiKey,
            completion: completion
        )
    }

    /// Vision path. Haiku-tier Claude models accept images; the photo is
    /// downscaled before this point (see RecipeImageEncoder) to keep the
    /// image-token cost down. Output cap is a little higher than the text
    /// path since the model is also doing the reading.
    func requestRecipe(
        fromJPEGData jpegData: Data,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    ) {
        let content: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ],
            ["type": "text", "text": AIRecipePrompt.visionInstructions]
        ]
        send(content: content, maxTokens: visionMaxTokens, apiKey: apiKey, completion: completion)
    }

    private let visionMaxTokens = 1500

    /// `content` is either a plain String (text path) or an array of
    /// content blocks (vision path) — the Messages API accepts both.
    private func send(
        content: Any,
        maxTokens: Int,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(AIProviderError.missingAPIKey))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]]
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

                guard let blocks = json?["content"] as? [[String: Any]],
                      let text = blocks.first?["text"] as? String else {
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
