import Foundation

/// One saved recipe's ingredients, as loaded for searching.
struct SearchCandidate {
    let recipeID: UUID
    let title: String
    /// Each ingredient line as written, with its reduced search names.
    let ingredients: [(text: String, terms: [String])]
}

/// What a recipe's ingredient list had for one thing the person searched.
struct TermMatch: Identifiable {
    let id = UUID()
    /// What was searched for.
    let query: String
    /// The recipe's ingredient line that matched best.
    let ingredientText: String
    /// 0...1; 1 is an exact match.
    let score: Double
}

struct IngredientMatch: Identifiable {
    let id: UUID
    let title: String
    /// Average closeness over everything searched (0...1).
    let score: Double
    let matches: [TermMatch]
    /// Searched terms the recipe has nothing close to.
    let missing: [String]
    let ingredientCount: Int
    /// True when every searched term is present (exactly or closely).
    var isComplete: Bool { missing.isEmpty }
}

/// Ranks recipes against a list of ingredients: first the recipes that have
/// everything, then the closest of the rest (most terms present, closest
/// wording). A term counts as present when the recipe's ingredient is the
/// same, a more specific version ("tomato" ↔ "cherry tomato"), a synonym
/// ("scallion" ↔ "green onion", via IngredientNormalizer) or a near-typo.
///
/// Mirrors Tools/search_prototype/search.py.
enum IngredientSearch {
    /// At least this close counts as "has it".
    static let strong = 0.6
    /// Below this a term isn't counted at all.
    static let weak = 0.35

    static func rank(queries: [String], candidates: [SearchCandidate]) -> [IngredientMatch] {
        guard !queries.isEmpty else { return [] }
        let queryTokens = queries.map { $0.split(separator: " ").map(String.init) }
        var results: [IngredientMatch] = []

        for candidate in candidates {
            // Tokenize each ingredient term once per recipe.
            let prepared: [(text: String, tokens: [String])] = candidate.ingredients.flatMap { ingredient in
                ingredient.terms.map { (text: ingredient.text, tokens: $0.split(separator: " ").map(String.init)) }
            }
            var matches: [TermMatch] = []
            var missing: [String] = []
            var total = 0.0

            for (index, query) in queries.enumerated() {
                var best = 0.0
                var bestText = ""
                for item in prepared {
                    let s = score(query: queryTokens[index], candidate: item.tokens)
                    if s > best { best = s; bestText = item.text }
                }
                if best >= weak {
                    matches.append(TermMatch(query: query, ingredientText: bestText, score: best))
                    total += best
                }
                if best < strong { missing.append(query) }
            }
            guard total > 0 else { continue }
            results.append(IngredientMatch(
                id: candidate.recipeID,
                title: candidate.title,
                score: total / Double(queries.count),
                matches: matches,
                missing: missing,
                ingredientCount: candidate.ingredients.count
            ))
        }

        return results.sorted { a, b in
            if a.isComplete != b.isComplete { return a.isComplete }
            if a.score != b.score { return a.score > b.score }
            if a.ingredientCount != b.ingredientCount { return a.ingredientCount < b.ingredientCount }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// How close one ingredient name is to another, 0...1. Word by word,
    /// weighted 75% toward covering what was searched and 25% toward not
    /// having many extra words.
    static func score(query: [String], candidate: [String]) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        var used = Set<Int>()
        var total = 0.0
        for word in query {
            var best = 0.0
            var bestIndex: Int?
            for (i, other) in candidate.enumerated() where !used.contains(i) {
                let m = wordMatch(word, other)
                if m > best { best = m; bestIndex = i }
            }
            if let bestIndex { used.insert(bestIndex); total += best }
        }
        guard total > 0 else { return 0 }
        return (total / Double(query.count)) * 0.75 + (total / Double(candidate.count)) * 0.25
    }

    private static func wordMatch(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let shorter = min(a.count, b.count)
        var allowed = 0
        if shorter >= 5 { allowed = 1 }
        if shorter >= 9 { allowed = 2 }
        guard allowed > 0 else { return 0 }
        return withinEditDistance(Array(a), Array(b), allowed) ? 0.9 : 0
    }

    private static func withinEditDistance(_ a: [Character], _ b: [Character], _ limit: Int) -> Bool {
        if abs(a.count - b.count) > limit { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                current.append(min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[b.count] <= limit
    }
}
