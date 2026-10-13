import Foundation

/// Anything that can turn OCR'd recipe text into a StructuredRecipe via a
/// cloud AI call implements this. The photo is OCR'd on-device first
/// (OCRTextExtractor) — only the resulting text is sent to the AI, which
/// is far cheaper than sending the image and lets you use a plain
/// text-only model instead of a vision model.
///
/// To add a new AI service later (a different vendor, a different model,
/// your own backend proxy, etc.), write one new type conforming to this
/// protocol — nothing else in the app needs to change. See
/// AnthropicRecipeProvider / OpenAIRecipeProvider for examples.
protocol AIRecipeProvider {
    /// Human-readable name shown in Settings.
    var displayName: String { get }

    /// The UserDefaults/Keychain key used to store this provider's API key.
    var apiKeyStorageKey: String { get }

    /// Where a user can go to generate an API key for this provider.
    var apiKeyHelpURL: URL? { get }

    func requestRecipe(
        fromOCRText ocrText: String,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    )

    /// Vision path: sends the photo itself (JPEG data) to a vision-capable
    /// model and has it find and structure the recipe directly. Costs more
    /// than the OCR-text path, so it is on-demand only (the button on the
    /// photo page), not the default.
    func requestRecipe(
        fromJPEGData jpegData: Data,
        apiKey: String,
        completion: @escaping (Result<StructuredRecipe, Error>) -> Void
    )
}

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case emptyOCRText
    case badResponse(String)
    case emptyResponse
    case emptyStructuredResult
    case noRecipeInImage
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set for this AI provider. Add one in Settings."
        case .emptyOCRText:
            return "On-device text recognition didn't find any text in that photo."
        case .badResponse(let detail):
            return "The AI service returned an error: \(detail)"
        case .emptyResponse:
            return "The AI service didn't return any recipe text."
        case .noRecipeInImage:
            return "The AI couldn't find a recipe in this photo. Try blocking out less of the page, retaking the photo, or switching AI engines in Settings."
        case .imageEncodingFailed:
            return "The photo couldn't be prepared for the AI."
        case .emptyStructuredResult:
            return "On-device text recognition found readable text in this photo, but the AI didn't return any ingredients or instructions from it. Try again, retake the photo, or switch AI engines in Settings."
        }
    }
}

/// Shared prompt so every provider asks for the same JSON shape,
/// which is what makes the output interchangeable between providers.
/// The input is raw OCR text, not a photo — it will contain recognition
/// errors, so the prompt tells the model to correct likely mistakes
/// (e.g. "l cup" -> "1 cup", "0nion" -> "onion") rather than transcribe
/// them literally.
///
/// The schema below matches StructuredRecipe (see StructuredRecipe.swift)
/// and is deliberately flexible: real recipes vary a lot in what they
/// print (some have two labeled ingredient lists, a tip, and a nutrition
/// panel; most have none of that) so every field beyond "title" is
/// optional, and the prompt explicitly tells the model not to invent
/// content just to fill a field that the source didn't have.
enum AIRecipePrompt {
    static let ocrIntro = """
    Below is text extracted from a photo of a recipe by on-device OCR. \
    The OCR may contain misread characters or merged/split words. For a \
    two-column layout (e.g. one ingredient list on the left, another \
    list or the steps on the right) the text has already been reordered \
    to give you the full left column top-to-bottom, then the full right \
    column top-to-bottom — that split is a heuristic and can be wrong, \
    so use context (units, verbs, step-like phrasing) to figure out \
    which lines are ingredients vs. instructions even if the boundary \
    looks abrupt. A blank line marks the transition from one column to \
    the other — it is not itself part of any ingredient or step.

    IMPORTANT — line-wrapping has already been resolved: each line below \
    is a complete ingredient or instruction step, not a fragment of one \
    — a separate process already rejoined any text that was split across \
    multiple printed lines because a column was too narrow. Do NOT try \
    to merge adjacent lines together yourself or treat a short line as \
    "the rest of" the line above it; take each line as already complete \
    and assign it to one ingredient/step, even if it reads a little \
    short (e.g. "2 large eggs" is a complete ingredient on its own, not \
    a fragment needing more text).

    IMPORTANT — never invent or substitute content: correcting an \
    obvious single-character OCR misread is fine (e.g. "l cup" -> \
    "1 cup", "0nion" -> "onion"), but if a fragment is unclear or you \
    are not confident how it reassembles, keep the OCR words as \
    literally as possible rather than replacing them with a different, \
    unrelated word or ingredient that merely "sounds plausible." An \
    odd-looking but literal transcription is far more useful here than \
    a smooth-sounding guess, since the person reading this will compare \
    it directly against the original photo. This applies to \
    instructions too: only include an action that the OCR text actually \
    describes — splitting one printed sentence into multiple numbered \
    steps at natural sentence boundaries is fine, but never add a step \
    or detail (e.g. "place the top bun") that isn't stated in the text, \
    even if it seems like an obvious next action.

    IMPORTANT — section headers control grouping: a short all-caps line, \
    often ending in a colon (e.g. "FOR CRAB CAKES:", "TARTAR SAUCE:"), \
    marks the start of a named group. Every ingredient or step line \
    belongs to the most recent such header above it in the OCR text — \
    assign items to groups by their position in the text, never by \
    guessing which group an item "should" logically belong to.
    """

    /// The JSON schema + rules, shared by the OCR-text prompt and the
    /// photo (vision) prompt so both engines return the same shape.
    static let schemaAndRules = """
    Respond with ONLY a JSON object — no markdown fences, no commentary \
    — matching EXACTLY this shape, with these EXACT key names (do not \
    use a flat top-level "ingredients" or "instructions" array — always \
    use the nested "ingredientGroups" / "instructionGroups" shape below, \
    even for a recipe with only one plain list):

    {
      "title": string,
      "description": string or null,
      "servings": string or null,
      "prepTime": string or null,
      "cookTime": string or null,
      "totalTime": string or null,
      "ingredientGroups": [ { "name": string or null, "items": [string, ...] }, ... ],
      "instructionGroups": [ { "name": string or null, "steps": [string, ...] }, ... ],
      "tips": [string, ...],
      "nutrition": [ { "label": string, "value": string }, ... ],
      "source": string or null
    }

    Rules:
    - "title" is the recipe name (a short guess like "Recipe" if none is visible).
    - Every field except "title" is optional. Omit a field, or use null / \
    an empty array, whenever the source recipe doesn't clearly have that \
    information — most recipes will NOT have named ingredient/instruction \
    groups, tips, or nutrition facts, and that is expected. Never invent \
    content to fill a field.
    - "ingredientGroups" almost always has exactly one entry with \
    "name": null, holding every ingredient as a flat list. Only split \
    into multiple named groups when the recipe visibly labels separate \
    sections (e.g. "Vinaigrette:" and "Salad:", or "Crust:" and \
    "Filling:"). Each item is one ingredient line including its \
    quantity/unit.
    - "instructionGroups" follows the same pattern as ingredientGroups: \
    one unnamed group holding a normal numbered list of steps, or \
    multiple named groups only when the recipe visibly separates steps \
    into labeled sections. Steps are listed in order, without leading \
    numbers (those are added when displayed).
    - "prepTime" / "cookTime" / "totalTime" / "servings" are short free \
    text copied as printed (e.g. "20 minutes", \
    "10 servings (3/4 cup vinaigrette)") — don't compute or reformat them.
    - "tips" holds any make-ahead notes, tips, or variations printed with \
    the recipe (often labeled "Tip:", "Note:", or "Variation:").
    - "nutrition" captures whatever per-serving nutrition facts are \
    printed, in the order they appear, e.g. {"label": "Calories", \
    "value": "238"}. Don't compute nutrition facts that aren't printed.
    - "source" is a printed attribution, website, or page number if \
    visible (e.g. "allrecipes.com, p. 12"); omit it if none is printed.
    - Only return "ingredientGroups": [] and "instructionGroups": [] if \
    the text is truly unrelated to a recipe (e.g. a receipt, an \
    unrelated article). Messy, reordered, or partially garbled OCR text \
    that still contains ingredient- or step-like content (quantities, \
    units, cooking verbs) is NOT a reason to return empty — do your best \
    to organize whatever recipe content is present. "Organizing what's \
    present" means assigning each already-complete line to the right \
    section and cleaning up obvious character-level OCR noise (per the \
    rules above) — it does NOT mean inventing content that isn't there. \
    Structuring effort and literal fidelity are not in tension: put in \
    the work to reconstruct the recipe's real structure, but never at \
    the cost of adding words, ingredients, or steps the OCR text doesn't \
    actually contain.
    """

    /// Prompt for the text-only path (on-device OCR first, then AI).
    /// Callers append "\n" + the OCR text.
    static let instructions = ocrIntro + "\n\n" + schemaAndRules + "\n\nOCR TEXT:"

    /// Prompt for the photo path: the AI reads the image directly.
    static let visionInstructions = visionIntro + "\n\n" + schemaAndRules

    static let visionIntro = """
    The attached image is a photo of a recipe, often a page from a \
    cookbook or binder. Find the recipe on the page and extract it. The \
    page may also show parts of OTHER, unrelated recipes — for example \
    the last lines of the previous recipe at the very top, or the start \
    of the next one at the bottom, sometimes faded or cut off. Extract \
    only the one main, complete recipe (the one with its own title, \
    ingredient list and method) and ignore text belonging to any other \
    recipe.

    Reading the layout: for a two-column layout (e.g. ingredients split \
    across a left and right column), read the whole left column top to \
    bottom, then the whole right column. An ingredient line wrapped onto \
    a second printed line is indented under the line above it and belongs \
    to that ingredient; a new ingredient starts flush with the list's \
    left margin, whether or not it begins with a quantity. Put everything \
    printed in the right fields: ingredients, the method/directions \
    (even when printed as one paragraph — split it into steps at natural \
    sentence boundaries), and any title, servings, times, tips, \
    nutrition or attribution.

    Transcribe literally and never invent content: copy quantities, \
    units and wording exactly as printed, and do not add ingredients or \
    steps that are not on the page. The rules below were written for \
    OCR'd text; wherever they say "OCR text" or "OCR", apply them to \
    what you read in the photo. If the photo contains no recipe at all, \
    return empty ingredientGroups and instructionGroups.
    """
}

