import Foundation

/// One editable row: an ingredient, a step, or a tip. Rows need a stable
/// `id` (unlike the plain strings in StructuredRecipe) so SwiftUI keeps
/// the right text field focused while the list is edited, reordered, or
/// split by pressing Return.
struct EditableLine: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(_ text: String = "") {
        self.id = UUID()
        self.text = text
    }

    /// Restores a row with its saved id (loading from the database).
    init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// A group of rows with an optional heading ("Vinaigrette", "Assemble").
/// An empty `name` means an ordinary unnamed list.
struct EditableGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var lines: [EditableLine]

    init(name: String = "", lines: [EditableLine] = []) {
        self.id = UUID()
        self.name = name
        self.lines = lines
    }

    init(id: UUID, name: String, lines: [EditableLine]) {
        self.id = id
        self.name = name
        self.lines = lines
    }
}

struct EditableFact: Identifiable, Equatable {
    let id: UUID
    var label: String
    var value: String

    init(label: String = "", value: String = "") {
        self.id = UUID()
        self.label = label
        self.value = value
    }

    init(id: UUID, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// The recipe as the editor works with it: every field a plain String
/// (never nil) and every list a list of identifiable rows. This is a
/// separate type from StructuredRecipe on purpose — StructuredRecipe is
/// the Codable shape the AI returns (and what a database will store), and
/// keeping the editing concerns here means that decoding code stays
/// untouched.
///
/// Convert in with `init(from:)`, out with `toStructured()`, which trims
/// text and drops empty rows/groups.
struct EditableRecipe: Equatable {
    var title = ""
    /// Which group the recipe is filed under on the main page (Breakfast,
    /// Dinner, …). Empty = uncategorized. Not part of the recipe text, so
    /// the Text view and the AI never see it.
    var category = ""
    /// One free-text block for everything that isn't the title, lists, tips
    /// or nutrition: servings, times, description and source, one per line
    /// ("Prep: 20 min"; any other line is the description). Kept as raw
    /// text while editing and split into StructuredRecipe's separate
    /// fields only in `toStructured()`, so typing in it is never
    /// reformatted underneath the cursor.
    var details = ""
    var ingredientGroups: [EditableGroup] = [EditableGroup()]
    var instructionGroups: [EditableGroup] = [EditableGroup()]
    var tips: [EditableLine] = []
    var nutrition: [EditableFact] = []
    /// Up to RecipePhotoLimits.maxPerRecipe pictures, each tied to an
    /// ingredient row, a step row, or (neither) the recipe itself. Not part
    /// of the recipe text, so StructuredRecipe / the Text view never see it.
    var photos: [RecipePhoto] = []

    init() {}

    init(from recipe: StructuredRecipe) {
        title = recipe.title
        details = Self.makeDetails(
            servings: recipe.servings, prep: recipe.prepTime, cook: recipe.cookTime,
            total: recipe.totalTime, description: recipe.description, source: recipe.source
        )
        ingredientGroups = recipe.ingredientGroups.map {
            EditableGroup(name: $0.name ?? "", lines: $0.items.map { EditableLine($0) })
        }
        instructionGroups = recipe.instructionGroups.map {
            EditableGroup(name: $0.name ?? "", lines: $0.steps.map { EditableLine($0) })
        }
        tips = recipe.tips.map { EditableLine($0) }
        nutrition = recipe.nutrition.map { EditableFact(label: $0.label, value: $0.value) }
        // The editor always needs at least one list to type into.
        if ingredientGroups.isEmpty { ingredientGroups = [EditableGroup()] }
        if instructionGroups.isEmpty { instructionGroups = [EditableGroup()] }
    }

    func toStructured() -> StructuredRecipe {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let ingredients: [IngredientGroup] = ingredientGroups.compactMap { group in
            let items = group.lines.compactMap { clean($0.text) }
            return items.isEmpty ? nil : IngredientGroup(name: clean(group.name), items: items)
        }
        let instructions: [InstructionGroup] = instructionGroups.compactMap { group in
            let steps = group.lines.compactMap { clean($0.text) }
            return steps.isEmpty ? nil : InstructionGroup(name: clean(group.name), steps: steps)
        }
        let facts: [NutritionFact] = nutrition.compactMap { fact in
            guard let label = clean(fact.label) else { return nil }
            return NutritionFact(label: label, value: clean(fact.value) ?? "")
        }
        let parsedDetails = Self.parseDetails(details)
        return StructuredRecipe(
            title: clean(title) ?? "",
            description: clean(parsedDetails.description),
            servings: clean(parsedDetails.servings),
            prepTime: clean(parsedDetails.prep),
            cookTime: clean(parsedDetails.cook),
            totalTime: clean(parsedDetails.total),
            ingredientGroups: ingredients,
            instructionGroups: instructions,
            tips: tips.compactMap { clean($0.text) },
            nutrition: facts,
            source: clean(parsedDetails.source)
        )
    }

    // MARK: - Cleaning and row identity

    /// A tidy copy: text trimmed, empty rows and groups dropped, details
    /// normalized. Unlike `EditableRecipe(from: toStructured())` this keeps
    /// every surviving row's id (and the pictures), which is what keeps a
    /// picture tied to the same ingredient or step across a Save.
    func cleaned() -> EditableRecipe {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func cleanGroups(_ groups: [EditableGroup]) -> [EditableGroup] {
            let result: [EditableGroup] = groups.compactMap { group in
                let lines = group.lines
                    .filter { !trimmed($0.text).isEmpty }
                    .map { EditableLine(id: $0.id, text: trimmed($0.text)) }
                return lines.isEmpty ? nil : EditableGroup(id: group.id, name: trimmed(group.name), lines: lines)
            }
            return result.isEmpty ? [EditableGroup()] : result
        }

        // Title, details, etc. come from the structured round trip.
        var result = EditableRecipe(from: toStructured())
        result.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        result.ingredientGroups = cleanGroups(ingredientGroups)
        result.instructionGroups = cleanGroups(instructionGroups)
        result.tips = tips
            .filter { !trimmed($0.text).isEmpty }
            .map { EditableLine(id: $0.id, text: trimmed($0.text)) }
        result.nutrition = nutrition
            .filter { !trimmed($0.label).isEmpty }
            .map { EditableFact(id: $0.id, label: trimmed($0.label), value: trimmed($0.value)) }
        result.photos = photos
        result.dropDanglingPhotoTies()
        return result
    }

    /// Gives rows whose text matches a row in `old` that row's id, so that
    /// pictures tied to it stay tied after the recipe text was edited as
    /// plain text (which re-creates every row). Matching is by exact text,
    /// in order, so duplicate lines pair up one-to-one.
    mutating func adoptRowIDs(from old: EditableRecipe) {
        func adopt(_ groups: inout [EditableGroup], from oldGroups: [EditableGroup]) {
            var available: [String: [UUID]] = [:]
            for line in oldGroups.flatMap({ $0.lines }) {
                available[line.text.trimmingCharacters(in: .whitespacesAndNewlines), default: []].append(line.id)
            }
            for g in groups.indices {
                for l in groups[g].lines.indices {
                    let key = groups[g].lines[l].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if var ids = available[key], !ids.isEmpty {
                        let id = ids.removeFirst()
                        available[key] = ids
                        groups[g].lines[l] = EditableLine(id: id, text: groups[g].lines[l].text)
                    }
                }
            }
        }
        adopt(&ingredientGroups, from: old.ingredientGroups)
        adopt(&instructionGroups, from: old.instructionGroups)
    }

    /// Pictures tied to an ingredient or step that no longer exists fall
    /// back to belonging to the recipe itself, rather than being lost.
    mutating func dropDanglingPhotoTies() {
        let ingredientIDs = Set(ingredientGroups.flatMap { $0.lines.map(\.id) })
        let stepIDs = Set(instructionGroups.flatMap { $0.lines.map(\.id) })
        for index in photos.indices {
            switch photos[index].attachment {
            case .recipe: break
            case .ingredient(let id): if !ingredientIDs.contains(id) { photos[index].attachment = .recipe }
            case .step(let id): if !stepIDs.contains(id) { photos[index].attachment = .recipe }
            }
        }
    }

    /// The same pictures, all attached to the recipe as a whole — used when
    /// an AI re-read replaces every ingredient and step with new rows.
    var photosDetachedFromRows: [RecipePhoto] {
        photos.map { photo in
            var copy = photo
            copy.attachment = .recipe
            return copy
        }
    }

    // MARK: - Details block

    struct ParsedDetails {
        var servings = ""
        var prep = ""
        var cook = ""
        var total = ""
        var description = ""
        var source = ""
    }

    /// Builds the details text block: one labeled line per value that
    /// exists, the description as plain lines, source last.
    static func makeDetails(
        servings: String?, prep: String?, cook: String?, total: String?,
        description: String?, source: String?
    ) -> String {
        func trimmed(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines: [String] = []
        for (label, value) in [("Servings", servings), ("Prep", prep), ("Cook", cook), ("Total", total)] {
            let v = trimmed(value)
            if !v.isEmpty { lines.append("\(label): \(v)") }
        }
        let d = trimmed(description)
        if !d.isEmpty { lines.append(d) }
        let src = trimmed(source)
        if !src.isEmpty { lines.append("Source: \(src)") }
        return lines.joined(separator: "\n")
    }

    /// Splits the details block back into fields. A line whose label (the
    /// text before the first colon) is a known one — Servings/Serves/Makes/
    /// Yield, Prep, Cook, Total (with or without "time"), Source — fills
    /// that field; every other line is part of the description.
    static func parseDetails(_ text: String) -> ParsedDetails {
        var out = ParsedDetails()
        var rest: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let colon = line.firstIndex(of: ":") {
                let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch label {
                case "servings", "serves", "makes", "yield": out.servings = value; continue
                case "prep", "prep time": out.prep = value; continue
                case "cook", "cook time": out.cook = value; continue
                case "total", "total time": out.total = value; continue
                case "source": out.source = value; continue
                default: break
                }
            }
            rest.append(line)
        }
        out.description = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    // MARK: - Plain-text view ("Text" mode in the editor)

    /// The recipe as plain text, for the editor's bulk-edit "Text" mode.
    /// Group names keep the case they were typed in (so switching back to
    /// fields doesn't turn "Tartar Sauce" into "TARTAR SAUCE").
    func toText() -> String {
        toStructured().renderedText(uppercaseGroupNames: false)
    }

    /// Reads text in the layout `toText()` produces back into rows. It is
    /// deliberately forgiving, since this is text a person has been
    /// typing in: blank lines are ignored, bullets and step numbers are
    /// optional, and "(none detected — edit me)" placeholders are dropped.
    static func parse(text: String) -> EditableRecipe {
        enum Section { case header, ingredients, instructions, tips, nutrition }

        var recipe = EditableRecipe()
        recipe.ingredientGroups = []
        recipe.instructionGroups = []

        var section = Section.header
        var titleSet = false
        var descriptionLines: [String] = []
        var servings = "", prep = "", cook = "", total = "", source = ""

        func stripListMarker(_ line: String) -> String {
            var s = line
            if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
            else if s.hasPrefix("• ") { s = String(s.dropFirst(2)) }
            s = s.replacingOccurrences(
                of: #"^\s*\d+[\.\)]\s*"#, with: "", options: .regularExpression
            )
            return s.trimmingCharacters(in: .whitespaces)
        }
        func isPlaceholder(_ s: String) -> Bool { s.contains("none detected") }
        func isGroupHeading(_ line: String) -> Bool {
            guard line.hasSuffix(":"), !line.hasPrefix("-"), !line.hasPrefix("•") else { return false }
            return line.range(of: #"^\d+[\.\)]"#, options: .regularExpression) == nil
        }
        func headingName(_ line: String) -> String {
            let name = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            // renderedText labels an unnamed group "OTHER" when a recipe
            // has several groups; that's not a real name.
            return name.uppercased() == "OTHER" ? "" : name
        }
        func add(_ item: String, to groups: inout [EditableGroup]) {
            guard !item.isEmpty, !isPlaceholder(item) else { return }
            if groups.isEmpty { groups.append(EditableGroup()) }
            groups[groups.count - 1].lines.append(EditableLine(item))
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()

            if upper == "INGREDIENTS" { section = .ingredients; continue }
            if upper == "INSTRUCTIONS" { section = .instructions; continue }
            if upper == "TIP" || upper == "TIPS" { section = .tips; continue }
            if upper.hasPrefix("NUTRITION") { section = .nutrition; continue }
            if upper.hasPrefix("SOURCE:") {
                source = String(line.dropFirst("Source:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            switch section {
            case .header:
                if !titleSet {
                    recipe.title = line
                    titleSet = true
                } else if ["PREP:", "COOK:", "TOTAL:", "MAKES:"].contains(where: { upper.hasPrefix($0) }) {
                    for segment in line.components(separatedBy: "//") {
                        let part = segment.trimmingCharacters(in: .whitespaces)
                        let value = part.drop(while: { $0 != ":" }).dropFirst()
                            .trimmingCharacters(in: .whitespaces)
                        switch part.uppercased() {
                        case let p where p.hasPrefix("PREP:"): prep = value
                        case let p where p.hasPrefix("COOK:"): cook = value
                        case let p where p.hasPrefix("TOTAL:"): total = value
                        case let p where p.hasPrefix("MAKES:"): servings = value
                        default: break
                        }
                    }
                } else {
                    descriptionLines.append(line)
                }
            case .ingredients:
                if isGroupHeading(line) {
                    recipe.ingredientGroups.append(EditableGroup(name: headingName(line)))
                } else {
                    add(stripListMarker(line), to: &recipe.ingredientGroups)
                }
            case .instructions:
                if isGroupHeading(line) {
                    recipe.instructionGroups.append(EditableGroup(name: headingName(line)))
                } else {
                    add(stripListMarker(line), to: &recipe.instructionGroups)
                }
            case .tips:
                let tip = stripListMarker(line)
                if !tip.isEmpty { recipe.tips.append(EditableLine(tip)) }
            case .nutrition:
                for pair in line.components(separatedBy: ", ") {
                    let pieces = pair.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    if pieces.count == 2 {
                        recipe.nutrition.append(EditableFact(label: pieces[0], value: pieces[1]))
                    } else if let only = pieces.first, !only.isEmpty {
                        recipe.nutrition.append(EditableFact(label: only))
                    }
                }
            }
        }

        recipe.details = makeDetails(
            servings: servings, prep: prep, cook: cook, total: total,
            description: descriptionLines.joined(separator: "\n"), source: source
        )
        if recipe.ingredientGroups.isEmpty { recipe.ingredientGroups = [EditableGroup()] }
        if recipe.instructionGroups.isEmpty { recipe.instructionGroups = [EditableGroup()] }
        return recipe
    }
}
