import UIKit

/// Abstraction so the parsing backend can be swapped out later
/// (e.g. for a cloud LLM call) without touching the UI.
protocol RecipeParsing {
    /// - Parameter excludedRegions: image-fraction rects (0...1, top-left
    ///   origin) the person drew in MaskEditorView to mark "don't read
    ///   this" — passed straight through to OCRTextExtractor.
    func parseRecipe(from image: UIImage, excludedRegions: [CGRect], completion: @escaping (Result<String, Error>) -> Void)
}

extension RecipeParsing {
    /// Convenience overload for call sites (previews, tests, etc.) that
    /// don't need masking.
    func parseRecipe(from image: UIImage, completion: @escaping (Result<String, Error>) -> Void) {
        parseRecipe(from: image, excludedRegions: [], completion: completion)
    }
}

enum RecipeParserError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The photo couldn't be read."
        }
    }
}

/// Uses Apple's on-device Vision framework to OCR the photo, then runs
/// a lightweight heuristic pass to structure it into a title,
/// ingredients, and instructions. Fully offline — no API key needed.
final class VisionRecipeParser: RecipeParsing {
    func parseRecipe(from image: UIImage, excludedRegions: [CGRect], completion: @escaping (Result<String, Error>) -> Void) {
        OCRTextExtractor.extractLines(from: image, excludedRegions: excludedRegions) { result in
            switch result {
            case .success(let lines):
                completion(.success(RecipeFormatter.format(lines: lines)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

/// Turns raw OCR lines into a readable Title / Ingredients / Instructions layout.
/// This is a heuristic, not a language model — it won't be perfect on every
/// layout, which is exactly why the result lands in an editable text view.
enum RecipeFormatter {
    static func format(lines rawLines: [String]) -> String {
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }

        let measurementUnits = [
            "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon",
            "teaspoons", "oz", "ounce", "ounces", "lb", "pound", "pounds", "g",
            "gram", "grams", "kg", "ml", "liter", "litre", "pinch", "clove",
            "cloves", "slice", "slices", "can", "cans"
        ]

        var title = lines[0]
        var ingredientLines: [String] = []
        var instructionLines: [String] = []
        var inInstructions = false

        for line in lines.dropFirst() {
            let lower = line.lowercased()
            let looksLikeStepNumber = line.range(
                of: #"^\s*(\d+[\.\)]|step\s*\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let looksLikeIngredient = measurementUnits.contains { lower.contains($0) }
                || line.range(of: #"^\s*\d+(/\d+)?\s"#, options: .regularExpression) != nil

            if looksLikeStepNumber {
                inInstructions = true
            }

            if inInstructions {
                instructionLines.append(line)
            } else if looksLikeIngredient {
                ingredientLines.append(line)
            } else if ingredientLines.isEmpty && instructionLines.isEmpty {
                // Likely a continuation of a multi-line title/subtitle.
                title += " " + line
            } else {
                ingredientLines.append(line)
            }
        }

        // Strip any pre-existing numbering — StructuredRecipe.renderedText() renumbers.
        let cleanedInstructions = instructionLines.map { line -> String in
            line.replacingOccurrences(
                of: #"^\s*(\d+[\.\)]|step\s*\d+[:\.]?)\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        let recipe = StructuredRecipe(
            title: title,
            ingredients: ingredientLines,
            instructions: cleanedInstructions
        )
        return recipe.renderedText()
    }
}
