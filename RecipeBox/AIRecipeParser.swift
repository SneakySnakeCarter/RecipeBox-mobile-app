import UIKit

/// Wraps any AIRecipeProvider so it conforms to the same RecipeParsing
/// protocol the on-device parser uses. Runs OCR locally first
/// (OCRTextExtractor) and sends only the resulting text to the AI — this
/// is what keeps AI cost down, since text tokens are far cheaper than
/// image tokens and the request doesn't need a vision-capable model.
///
/// ContentView / RecipeParserFactory don't know or care whether the
/// active engine is on-device, Claude, or ChatGPT — they all speak
/// RecipeParsing.
struct AIRecipeParser: RecipeParsing {
    let provider: AIRecipeProvider
    let apiKey: String

    func parseRecipe(from source: StitchedImage, excludedRegions: [CGRect], completion: @escaping (Result<StructuredRecipe, Error>) -> Void) {
        OCRTextExtractor.extractLines(from: source, excludedRegions: excludedRegions) { ocrResult in
            switch ocrResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let lines):
                let ocrText = lines.joined(separator: "\n")
                provider.requestRecipe(fromOCRText: ocrText, apiKey: apiKey) { aiResult in
                    switch aiResult {
                    case .success(let recipe):
                        // OCR clearly found substantial text (more than a
                        // stray word or two) but the AI's structured
                        // result has no ingredients or instructions at
                        // all. That's very unlikely to be a genuinely
                        // empty recipe — far more likely the response
                        // didn't parse the way this app expected. Surface
                        // it as an error instead of silently showing a
                        // blank recipe as if that were the real answer.
                        let hasSubstantialOCRText = ocrText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .count > 40
                        if hasSubstantialOCRText && !recipe.hasAnyContent {
                            completion(.failure(AIProviderError.emptyStructuredResult))
                        } else {
                            completion(.success(recipe))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }
}

/// The on-demand vision path: sends the photo itself to the active AI
/// provider and returns the rendered recipe text. Unlike AIRecipeParser it
/// does no local OCR — the model reads the image directly, which handles
/// layouts and stray neighbouring-recipe text better but costs more per
/// call, so it's triggered by a button rather than being the default.
struct AIImageRecipeParser {
    let provider: AIRecipeProvider
    let apiKey: String
    /// Regions blocked out in MaskEditorView; painted white before upload.
    let excludedRegions: [CGRect]

    func parseRecipe(from source: StitchedImage, completion: @escaping (Result<StructuredRecipe, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pieces = RecipeImageEncoder.jpegPieces(from: source, blockingRegions: excludedRegions)
            guard !pieces.isEmpty else {
                completion(.failure(AIProviderError.imageEncodingFailed))
                return
            }
            provider.requestRecipe(fromJPEGImages: pieces, apiKey: apiKey) { result in
                switch result {
                case .success(let recipe):
                    if recipe.hasAnyContent {
                        completion(.success(recipe))
                    } else {
                        completion(.failure(AIProviderError.noRecipeInImage))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}
