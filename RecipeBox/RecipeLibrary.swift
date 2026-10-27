import Foundation
import CoreGraphics

struct RecipeSummary: Identifiable {
    let id: UUID
    var title: String
    /// "" when the recipe has no category.
    var category: String
    var updatedAt: Date
    var ingredientCount: Int
    var photoCount: Int
}

/// Everything stored for one recipe, as read back from the database.
struct LibraryRecord {
    var recipe: EditableRecipe
    /// The photo(s) the recipe was read from, top to bottom (empty for
    /// pasted or shared text).
    var sourceRefs: [StoredImageRef]
    /// The text, for a recipe that came from pasted / shared text.
    var sourceText: String?
    /// Areas blocked out before reading (fractions of the image).
    var excludedRegions: [CGRect]
    /// Whether overlap was cut out when several photos were joined.
    var removeOverlap: Bool
}

/// The saved-recipe database (SQLite, in the app's Application Support
/// folder). One shared instance; every call is serialized on one queue, so
/// it is safe to call from anywhere.
final class RecipeLibrary {
    static let shared = RecipeLibrary()

    private let queue = DispatchQueue(label: "recipebox.library")
    private var database: SQLiteDatabase?
    /// Set when the database file couldn't be opened.
    private(set) var openError: String?

    private init() {
        do {
            database = try Self.openDatabase()
        } catch {
            openError = error.localizedDescription
        }
    }

    private static func openDatabase() throws -> SQLiteDatabase {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("RecipeBox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: folder.appendingPathComponent("recipes.sqlite").path)

        // Migrations: each schema version runs once, in order.
        if db.userVersion < 1 {
            try db.transaction {
                try db.script(RecipeSchema.version1)
                db.userVersion = 1
            }
        }
        if db.userVersion < 2 {
            try db.transaction {
                try db.script(RecipeSchema.version2)
                db.userVersion = 2
            }
        }
        return db
    }

    // MARK: - Plumbing

    private func withDatabase<T>(_ work: (SQLiteDatabase) throws -> T) throws -> T {
        guard let database else {
            throw SQLiteDatabase.SQLiteError(message: openError ?? "The recipe database isn't available.")
        }
        return try work(database)
    }

    private func perform<T>(_ work: (SQLiteDatabase) throws -> T) throws -> T {
        try queue.sync { try withDatabase(work) }
    }

    // MARK: - Saving

    /// Stores (or updates) a recipe, replacing everything saved under `id`.
    /// Row ids come from the recipe's rows, so pictures stay tied to the
    /// same ingredient / step. All-or-nothing.
    func save(
        id: UUID,
        recipe: EditableRecipe,
        sourceRefs: [StoredImageRef],
        sourceText: String?,
        excludedRegions: [CGRect],
        removeOverlap: Bool
    ) throws {
        let clean = recipe.cleaned()
        let structured = clean.toStructured()
        let now = Date().timeIntervalSince1970
        let regions = excludedRegions.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        let regionsJSON = (try? JSONEncoder().encode(regions)).flatMap { String(data: $0, encoding: .utf8) }
        let key = SQLiteDatabase.Value.text(id.uuidString)

        try perform { db in
            try db.transaction {
                try db.run("""
                    INSERT INTO recipe (id, title, category, description, servings, prep_time, cook_time, total_time,
                                        source, source_text, excluded_regions, stitch_overlap, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, category = excluded.category, description = excluded.description,
                        servings = excluded.servings, prep_time = excluded.prep_time,
                        cook_time = excluded.cook_time, total_time = excluded.total_time,
                        source = excluded.source, source_text = excluded.source_text,
                        excluded_regions = excluded.excluded_regions,
                        stitch_overlap = excluded.stitch_overlap, updated_at = excluded.updated_at
                    """, [
                        key, .text(structured.title), .text(clean.category), .optional(structured.description),
                        .optional(structured.servings), .optional(structured.prepTime),
                        .optional(structured.cookTime), .optional(structured.totalTime),
                        .optional(structured.source), .optional(sourceText), .optional(regionsJSON),
                        .int(removeOverlap ? 1 : 0), .real(now), .real(now)
                    ])

                // Children are rewritten from scratch (pictures first: they
                // point at ingredients and steps).
                for table in ["photo", "ingredient_term", "ingredient", "step", "tip", "nutrition", "source_image"] {
                    try db.run("DELETE FROM \(table) WHERE recipe_id = ?", [key])
                }

                var position = 0
                for (groupIndex, group) in clean.ingredientGroups.enumerated() {
                    for line in group.lines {
                        try db.run(
                            "INSERT INTO ingredient (id, recipe_id, group_index, group_name, position, text) VALUES (?, ?, ?, ?, ?, ?)",
                            [.uuid(line.id), key, .int(Int64(groupIndex)), .text(group.name), .int(Int64(position)), .text(line.text)]
                        )
                        for term in IngredientNormalizer.terms(fromLine: line.text) {
                            try db.run(
                                "INSERT INTO ingredient_term (ingredient_id, recipe_id, term) VALUES (?, ?, ?)",
                                [.uuid(line.id), key, .text(term)]
                            )
                        }
                        position += 1
                    }
                }

                position = 0
                for (groupIndex, group) in clean.instructionGroups.enumerated() {
                    for line in group.lines {
                        try db.run(
                            "INSERT INTO step (id, recipe_id, group_index, group_name, position, text) VALUES (?, ?, ?, ?, ?, ?)",
                            [.uuid(line.id), key, .int(Int64(groupIndex)), .text(group.name), .int(Int64(position)), .text(line.text)]
                        )
                        position += 1
                    }
                }

                for (index, tip) in clean.tips.enumerated() {
                    try db.run(
                        "INSERT INTO tip (id, recipe_id, position, text) VALUES (?, ?, ?, ?)",
                        [.uuid(tip.id), key, .int(Int64(index)), .text(tip.text)]
                    )
                }
                for (index, fact) in clean.nutrition.enumerated() {
                    try db.run(
                        "INSERT INTO nutrition (id, recipe_id, position, label, value) VALUES (?, ?, ?, ?, ?)",
                        [.uuid(fact.id), key, .int(Int64(index)), .text(fact.label), .text(fact.value)]
                    )
                }

                for (index, photo) in clean.photos.prefix(RecipePhotoLimits.maxPerRecipe).enumerated() {
                    var ingredientID: UUID?
                    var stepID: UUID?
                    switch photo.attachment {
                    case .recipe: break
                    case .ingredient(let rowID): ingredientID = rowID
                    case .step(let rowID): stepID = rowID
                    }
                    try db.run("""
                        INSERT INTO photo (id, recipe_id, position, storage, location, ingredient_id, step_id, caption)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, [
                            .uuid(photo.id), key, .int(Int64(index)), .text(photo.ref.storage),
                            .text(photo.ref.location), .uuid(ingredientID), .uuid(stepID), .text(photo.caption)
                        ])
                }

                for (index, ref) in sourceRefs.enumerated() {
                    try db.run(
                        "INSERT INTO source_image (recipe_id, position, storage, location) VALUES (?, ?, ?, ?)",
                        [key, .int(Int64(index)), .text(ref.storage), .text(ref.location)]
                    )
                }
            }
        }
    }

    // MARK: - Reading

    func load(id: UUID) throws -> LibraryRecord? {
        try perform { db -> LibraryRecord? in
            let key = SQLiteDatabase.Value.text(id.uuidString)
            var recipe = EditableRecipe()
            var sourceText: String?
            var regions: [CGRect] = []
            var removeOverlap = false
            var found = false

            try db.query("""
                SELECT title, description, servings, prep_time, cook_time, total_time, source,
                       source_text, excluded_regions, stitch_overlap, category
                FROM recipe WHERE id = ?
                """, [key]) { row in
                found = true
                recipe.title = row.string(0)
                recipe.category = row.string(10)
                recipe.details = EditableRecipe.makeDetails(
                    servings: row.optionalString(2), prep: row.optionalString(3),
                    cook: row.optionalString(4), total: row.optionalString(5),
                    description: row.optionalString(1), source: row.optionalString(6)
                )
                sourceText = row.optionalString(7)
                if let json = row.optionalString(8),
                   let data = json.data(using: .utf8),
                   let raw = try? JSONDecoder().decode([[Double]].self, from: data) {
                    regions = raw.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
                }
                removeOverlap = row.int(9) != 0
            }
            guard found else { return nil }

            func groups(_ table: String) throws -> [EditableGroup] {
                var byIndex: [Int: EditableGroup] = [:]
                var order: [Int] = []
                try db.query(
                    "SELECT id, group_index, group_name, text FROM \(table) WHERE recipe_id = ? ORDER BY group_index, position",
                    [key]
                ) { row in
                    let index = row.int(1)
                    if byIndex[index] == nil {
                        byIndex[index] = EditableGroup(id: UUID(), name: row.string(2), lines: [])
                        order.append(index)
                    }
                    byIndex[index]?.lines.append(EditableLine(id: row.uuid(0) ?? UUID(), text: row.string(3)))
                }
                let result = order.compactMap { byIndex[$0] }
                return result.isEmpty ? [EditableGroup()] : result
            }
            recipe.ingredientGroups = try groups("ingredient")
            recipe.instructionGroups = try groups("step")

            try db.query("SELECT id, text FROM tip WHERE recipe_id = ? ORDER BY position", [key]) { row in
                recipe.tips.append(EditableLine(id: row.uuid(0) ?? UUID(), text: row.string(1)))
            }
            try db.query("SELECT id, label, value FROM nutrition WHERE recipe_id = ? ORDER BY position", [key]) { row in
                recipe.nutrition.append(EditableFact(id: row.uuid(0) ?? UUID(), label: row.string(1), value: row.string(2)))
            }
            try db.query("""
                SELECT id, storage, location, ingredient_id, step_id, caption
                FROM photo WHERE recipe_id = ? ORDER BY position
                """, [key]) { row in
                guard let ref = StoredImageRef(storage: row.string(1), location: row.string(2)) else { return }
                var attachment = PhotoAttachment.recipe
                if let ingredient = row.uuid(3) { attachment = .ingredient(ingredient) }
                else if let step = row.uuid(4) { attachment = .step(step) }
                recipe.photos.append(RecipePhoto(
                    id: row.uuid(0) ?? UUID(), ref: ref, attachment: attachment, caption: row.string(5)
                ))
            }

            var sourceRefs: [StoredImageRef] = []
            try db.query("SELECT storage, location FROM source_image WHERE recipe_id = ? ORDER BY position", [key]) { row in
                if let ref = StoredImageRef(storage: row.string(0), location: row.string(1)) {
                    sourceRefs.append(ref)
                }
            }

            return LibraryRecord(
                recipe: recipe, sourceRefs: sourceRefs, sourceText: sourceText,
                excludedRegions: regions, removeOverlap: removeOverlap
            )
        }
    }

    /// Saved recipes, most recently changed first, optionally only those
    /// whose title contains `titleContains`.
    func summaries(titleContains: String? = nil) throws -> [RecipeSummary] {
        try perform { db -> [RecipeSummary] in
            var sql = """
                SELECT r.id, r.title, r.updated_at,
                       (SELECT COUNT(*) FROM ingredient WHERE recipe_id = r.id),
                       (SELECT COUNT(*) FROM photo WHERE recipe_id = r.id),
                       r.category
                FROM recipe r
                """
            var values: [SQLiteDatabase.Value] = []
            let needle = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !needle.isEmpty {
                sql += " WHERE r.title LIKE ? ESCAPE '\\'"
                let escaped = needle
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                values.append(.text("%\(escaped)%"))
            }
            sql += " ORDER BY r.title COLLATE NOCASE"

            var result: [RecipeSummary] = []
            try db.query(sql, values) { row in
                guard let id = row.uuid(0) else { return }
                result.append(RecipeSummary(
                    id: id, title: row.string(1), category: row.string(5),
                    updatedAt: Date(timeIntervalSince1970: row.double(2)),
                    ingredientCount: row.int(3), photoCount: row.int(4)
                ))
            }
            return result
        }
    }

    /// Every category in use, for the editor's Category menu.
    func categoryNames() -> [String] {
        (try? perform { db -> [String] in
            var names: [String] = []
            try db.query("SELECT DISTINCT category FROM recipe WHERE category <> '' ORDER BY category COLLATE NOCASE") {
                names.append($0.string(0))
            }
            return names
        }) ?? []
    }

    func recipeExists(id: UUID) -> Bool {
        (try? perform { db -> Bool in
            var exists = false
            try db.query("SELECT 1 FROM recipe WHERE id = ?", [.text(id.uuidString)]) { _ in exists = true }
            return exists
        }) ?? false
    }

    // MARK: - Deleting and cleanup

    func delete(id: UUID) throws {
        var files: [String] = []
        try perform { db in
            let key = SQLiteDatabase.Value.text(id.uuidString)
            for sql in [
                "SELECT location FROM photo WHERE recipe_id = ? AND storage = 'file'",
                "SELECT location FROM source_image WHERE recipe_id = ? AND storage = 'file'"
            ] {
                try db.query(sql, [key]) { files.append($0.string(0)) }
            }
            try db.run("DELETE FROM recipe WHERE id = ?", [key])
        }
        // Only files are removed; photos in the person's library are never touched.
        for name in files { PhotoStore.delete(.file(name)) }
    }

    /// Removes photo files that no saved recipe uses. Call once at launch.
    func collectGarbage() {
        guard let names = try? perform({ db -> Set<String> in
            var names = Set<String>()
            for sql in [
                "SELECT location FROM photo WHERE storage = 'file'",
                "SELECT location FROM source_image WHERE storage = 'file'"
            ] {
                try db.query(sql) { names.insert($0.string(0)) }
            }
            return names
        }) else { return }
        PhotoStore.collectGarbage(keeping: names)
    }

    // MARK: - Ingredient search

    /// Finds recipes by ingredient: those that have everything first, then
    /// the closest of the rest. `terms` are already-reduced ingredient names
    /// (IngredientNormalizer). Runs in the background; completes on the main queue.
    func searchByIngredients(
        terms: [String],
        completion: @escaping (Result<[IngredientMatch], Error>) -> Void
    ) {
        queue.async {
            let result = Result<[IngredientMatch], Error> {
                let candidates = try self.withDatabase { try Self.loadCandidates($0) }
                return IngredientSearch.rank(queries: terms, candidates: candidates)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func loadCandidates(_ db: SQLiteDatabase) throws -> [SearchCandidate] {
        struct Pending {
            var title: String
            var order: [UUID] = []
            var lines: [UUID: (text: String, terms: [String])] = [:]
        }
        var recipes: [UUID: Pending] = [:]
        var recipeOrder: [UUID] = []

        try db.query("""
            SELECT r.id, r.title, i.id, i.text, t.term
            FROM recipe r
            JOIN ingredient i ON i.recipe_id = r.id
            LEFT JOIN ingredient_term t ON t.ingredient_id = i.id
            ORDER BY r.id, i.position
            """) { row in
            guard let recipeID = row.uuid(0), let ingredientID = row.uuid(2) else { return }
            if recipes[recipeID] == nil {
                recipes[recipeID] = Pending(title: row.string(1))
                recipeOrder.append(recipeID)
            }
            if recipes[recipeID]?.lines[ingredientID] == nil {
                recipes[recipeID]?.lines[ingredientID] = (row.string(3), [])
                recipes[recipeID]?.order.append(ingredientID)
            }
            if let term = row.optionalString(4) {
                recipes[recipeID]?.lines[ingredientID]?.terms.append(term)
            }
        }

        return recipeOrder.compactMap { id in
            guard let pending = recipes[id] else { return nil }
            let ingredients = pending.order.compactMap { pending.lines[$0] }
            return SearchCandidate(recipeID: id, title: pending.title, ingredients: ingredients)
        }
    }
}

/// What the Compare screen needs to save its recipe to the library: the
/// id it is (or will be) stored under and where it came from.
struct LibraryInfo {
    var id = UUID()
    var sourceRefs: [StoredImageRef] = []
    var sourceText: String?
    var removeOverlap = false
    /// True when the recipe is already stored (opened from My Recipes).
    var isSaved = false
}
