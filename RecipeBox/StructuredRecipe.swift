import Foundation

/// One labeled group of ingredients (e.g. "Vinaigrette" vs "Salad" on a
/// recipe that prints two separate ingredient lists). `name` is nil for
/// the common case of a recipe with a single, flat ingredient list —
/// nothing downstream needs to special-case that; a lone unnamed group
/// just renders as a plain list with no header.
struct IngredientGroup: Codable {
    var name: String?
    var items: [String]

    init(name: String? = nil, items: [String]) {
        self.name = name
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case name, items }

    /// Custom decode so a group missing "name" or "items" (which happens
    /// with AI output more often than it should) doesn't fail the whole
    /// recipe — it just falls back to nil/empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
    }
}

/// One labeled group of instruction steps (e.g. "Make the vinaigrette"
/// vs "Assemble the salad"). Same idea, and same reason, as IngredientGroup.
struct InstructionGroup: Codable {
    var name: String?
    var steps: [String]

    init(name: String? = nil, steps: [String]) {
        self.name = name
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey { case name, steps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
    }
}

/// A single printed nutrition fact, e.g. label "Calories", value "238".
/// Kept as loose, ordered label/value pairs rather than a fixed set of
/// named fields (calories, fat, sodium, ...), since recipes print wildly
/// different sets of facts — or none at all — and a fixed struct would
/// either drop whatever isn't on the list or need constant updating.
struct NutritionFact: Codable {
    var label: String
    var value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case label, value }

    /// Lenient like the two group types above: a nutrition entry missing
    /// one field falls back to an empty string rather than failing the
    /// whole recipe's decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// A structured recipe. Every parsing engine (on-device heuristic or AI)
/// produces one of these, then renders it to the same plain-text layout —
/// so the editable text page looks and behaves identically no matter
/// which engine produced it.
///
/// Only `title` is guaranteed to be meaningful. Everything else is
/// optional or can be an empty array, because most source recipes don't
/// have every section (grouped ingredients, prep/cook time, tips,
/// nutrition, a printed source) — a simple recipe with one ingredient
/// list and nothing else renders exactly as compactly as it always has.
struct StructuredRecipe: Codable {
    var title: String
    var description: String?
    var servings: String?
    var prepTime: String?
    var cookTime: String?
    var totalTime: String?
    var ingredientGroups: [IngredientGroup]
    var instructionGroups: [InstructionGroup]
    var tips: [String]
    var nutrition: [NutritionFact]
    var source: String?

    init(
        title: String,
        description: String? = nil,
        servings: String? = nil,
        prepTime: String? = nil,
        cookTime: String? = nil,
        totalTime: String? = nil,
        ingredientGroups: [IngredientGroup] = [],
        instructionGroups: [InstructionGroup] = [],
        tips: [String] = [],
        nutrition: [NutritionFact] = [],
        source: String? = nil
    ) {
        self.title = title
        self.description = description
        self.servings = servings
        self.prepTime = prepTime
        self.cookTime = cookTime
        self.totalTime = totalTime
        self.ingredientGroups = ingredientGroups
        self.instructionGroups = instructionGroups
        self.tips = tips
        self.nutrition = nutrition
        self.source = source
    }

    /// Convenience initializer for the common case of one flat ingredient
    /// list and one flat instruction list with no grouping, tips, or
    /// nutrition — this is what the on-device heuristic parser produces,
    /// since simple line-pattern matching has no way to detect section
    /// headers or a printed nutrition panel.
    init(title: String, ingredients: [String], instructions: [String]) {
        self.init(
            title: title,
            ingredientGroups: ingredients.isEmpty ? [] : [IngredientGroup(items: ingredients)],
            instructionGroups: instructions.isEmpty ? [] : [InstructionGroup(steps: instructions)]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, servings, prepTime, cookTime, totalTime
        case ingredientGroups, instructionGroups, tips, nutrition, source
    }

    /// Older/simpler prompt versions (and, in practice, a cheap model
    /// reverting to a more familiar shape despite instructions) used a
    /// flat "ingredients": [string] / "instructions": [string] schema
    /// instead of the current grouped one. Recognized as a fallback below
    /// so that regression doesn't silently produce an empty recipe.
    private enum LegacyCodingKeys: String, CodingKey {
        case ingredients, instructions
    }

    /// Custom decode, all-optional: an AI response that omits a field
    /// entirely (which is the expected, encouraged behavior for sections
    /// a recipe doesn't have) decodes to nil/empty rather than throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        servings = try c.decodeIfPresent(String.self, forKey: .servings)
        prepTime = try c.decodeIfPresent(String.self, forKey: .prepTime)
        cookTime = try c.decodeIfPresent(String.self, forKey: .cookTime)
        totalTime = try c.decodeIfPresent(String.self, forKey: .totalTime)
        ingredientGroups = try c.decodeIfPresent([IngredientGroup].self, forKey: .ingredientGroups) ?? []
        instructionGroups = try c.decodeIfPresent([InstructionGroup].self, forKey: .instructionGroups) ?? []
        tips = try c.decodeIfPresent([String].self, forKey: .tips) ?? []
        nutrition = try c.decodeIfPresent([NutritionFact].self, forKey: .nutrition) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)

        // Fallback for a response that used the old flat schema: only
        // consulted when the new grouped keys came back empty, so it
        // never overrides a correctly-formed grouped response.
        if ingredientGroups.isEmpty || instructionGroups.isEmpty {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if ingredientGroups.isEmpty,
               let flatIngredients = try legacy.decodeIfPresent([String].self, forKey: .ingredients),
               !flatIngredients.isEmpty {
                ingredientGroups = [IngredientGroup(items: flatIngredients)]
            }
            if instructionGroups.isEmpty,
               let flatInstructions = try legacy.decodeIfPresent([String].self, forKey: .instructions),
               !flatInstructions.isEmpty {
                instructionGroups = [InstructionGroup(steps: flatInstructions)]
            }
        }
    }

    /// True when at least one ingredient or instruction step was found.
    /// Used to tell "the AI genuinely found nothing in this photo" apart
    /// from "the response didn't parse the way this app expected" — see
    /// AIRecipeParser, which treats an empty result as an error rather
    /// than a successful-but-blank recipe when the OCR text clearly had
    /// real content.
    var hasAnyContent: Bool {
        ingredientGroups.contains { !$0.items.isEmpty }
            || instructionGroups.contains { !$0.steps.isEmpty }
    }

    /// Renders to the plain-text layout shown in the editable recipe
    /// page. Sections with no content are omitted entirely — a simple
    /// recipe (one ingredient list, no tips/nutrition) renders identically
    /// to the original three-field version of this model; a recipe with
    /// grouped ingredients, prep/cook time, tips, and nutrition shows all
    /// of it, each under its own heading.
    func renderedText() -> String {
        var lines: [String] = []
        lines.append(title.isEmpty ? "Untitled Recipe" : title)

        var meta: [String] = []
        if let prepTime, !prepTime.isEmpty { meta.append("Prep: \(prepTime)") }
        if let cookTime, !cookTime.isEmpty { meta.append("Cook: \(cookTime)") }
        if let totalTime, !totalTime.isEmpty { meta.append("Total: \(totalTime)") }
        if let servings, !servings.isEmpty { meta.append("Makes: \(servings)") }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: "   //   "))
        }

        if let description, !description.isEmpty {
            lines.append("")
            lines.append(description)
        }

        lines.append("")
        lines.append("INGREDIENTS")
        let ingredientSections = ingredientGroups.filter { !$0.items.isEmpty }
        if ingredientSections.isEmpty {
            lines.append("- (none detected — edit me)")
        } else if ingredientSections.count == 1, isUnnamed(ingredientSections[0].name) {
            lines.append(contentsOf: ingredientSections[0].items.map { "- \($0)" })
        } else {
            for (index, group) in ingredientSections.enumerated() {
                if index > 0 { lines.append("") }
                lines.append("\(sectionHeading(group.name)):")
                lines.append(contentsOf: group.items.map { "- \($0)" })
            }
        }

        lines.append("")
        lines.append("INSTRUCTIONS")
        let instructionSections = instructionGroups.filter { !$0.steps.isEmpty }
        if instructionSections.isEmpty {
            lines.append("1. (none detected — edit me)")
        } else if instructionSections.count == 1, isUnnamed(instructionSections[0].name) {
            let numbered = instructionSections[0].steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
            lines.append(contentsOf: numbered)
        } else {
            for (index, group) in instructionSections.enumerated() {
                if index > 0 { lines.append("") }
                lines.append("\(sectionHeading(group.name)):")
                let numbered = group.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
                lines.append(contentsOf: numbered)
            }
        }

        if !tips.isEmpty {
            lines.append("")
            lines.append(tips.count == 1 ? "TIP" : "TIPS")
            lines.append(contentsOf: tips.map { "- \($0)" })
        }

        let nutritionFacts = nutrition.filter { !$0.label.isEmpty }
        if !nutritionFacts.isEmpty {
            lines.append("")
            lines.append("NUTRITION (per serving)")
            lines.append(nutritionFacts.map { "\($0.label): \($0.value)" }.joined(separator: ", "))
        }

        if let source, !source.isEmpty {
            lines.append("")
            lines.append("Source: \(source)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func isUnnamed(_ name: String?) -> Bool {
        guard let name else { return true }
        return name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sectionHeading(_ name: String?) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "OTHER" }
        return name.uppercased()
    }
}
