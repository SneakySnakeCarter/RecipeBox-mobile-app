import UIKit

/// Reading a recipe from text that is already text (pasted, or shared from
/// another app) — no photo, so no OCR step. Goes straight to the AI text
/// path, or the on-device formatter when that engine is selected.
enum TextRecipeParser {

    static func parse(_ text: String, completion: @escaping (Result<StructuredRecipe, Error>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = UserDefaults.standard.string(forKey: ParserSettingsKeys.selectedEngine)
        let engine = ParserEngine(rawValue: rawValue ?? "") ?? .claude

        guard let provider = engine.aiProvider else {
            let lines = trimmed.components(separatedBy: .newlines)
            completion(.success(RecipeFormatter.structure(lines: lines)))
            return
        }

        let apiKey = KeychainHelper.shared.read(forKey: provider.apiKeyStorageKey) ?? ""
        provider.requestRecipe(fromOCRText: trimmed, apiKey: apiKey) { result in
            switch result {
            case .success(let recipe):
                // Same guard as the photo path: plenty of text in, nothing
                // out almost always means the reply didn't parse.
                if trimmed.count > 40 && !recipe.hasAnyContent {
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

/// The Compare screen's second page shows "the original". For pasted or
/// shared text there is no photo, so the text is drawn onto a plain page
/// and used as the original instead — which also keeps the AI Re-read
/// button working.
enum TextCardRenderer {

    static func render(_ text: String) -> StitchedImage {
        let width: CGFloat = 1100
        let margin: CGFloat = 56
        let maxHeight: CGFloat = 12_000

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 32),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]

        let textWidth = width - margin * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let height = min(ceil(bounds.height) + margin * 2, maxHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
            (text as NSString).draw(
                with: CGRect(x: margin, y: margin, width: textWidth, height: height - margin * 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        }
        return .single(image)
    }
}
