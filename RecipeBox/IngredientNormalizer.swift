import Foundation

/// Reduces an ingredient line to the plain ingredient name(s) used for
/// searching: "1 1/2 cups all-purpose flour, sifted" → "all purpose flour",
/// "Salt and pepper to taste" → "salt", "pepper".
///
/// Searching only ever compares these reduced names (the line the person
/// sees is stored untouched). Both stored ingredients and search queries go
/// through the same function, so quirks (like a particular plural rule)
/// apply equally to both sides and cancel out.
///
/// Mirrors Tools/search_prototype/search.py, which was used to tune the word
/// lists below against sample ingredient lines.
enum IngredientNormalizer {

    // Measures and containers. Dropped unless nothing would follow them
    // ("ground cloves" keeps "clove"; "3 cloves garlic" drops it).
    private static let units: Set<String> = [
        "cup", "cups", "c", "tablespoon", "tablespoons", "tbsp", "tbs", "tbl", "teaspoon", "teaspoons", "tsp",
        "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs", "gram", "grams", "g", "kg", "kilogram",
        "ml", "milliliter", "liter", "litre", "liters", "l", "quart", "quarts", "qt", "pint", "pints", "pt",
        "gallon", "gal", "pinch", "pinches", "dash", "clove", "cloves", "can", "cans", "jar", "jars",
        "package", "packages", "pkg", "packet", "packets", "stick", "sticks", "slice", "slices",
        "bunch", "bunches", "sprig", "sprigs", "head", "heads", "handful", "piece", "pieces", "dozen",
        "container", "bottle", "bottles", "bag", "bags", "box", "boxes", "stalk", "stalks", "ear", "ears"
    ]

    // Size, preparation and filler words that say nothing about *which*
    // ingredient it is.
    private static let noise: Set<String> = [
        "fresh", "freshly", "large", "small", "medium", "chopped", "minced", "diced", "sliced", "grated",
        "shredded", "crushed", "peeled", "cubed", "halved", "divided", "softened", "melted", "packed",
        "optional", "about", "finely", "roughly", "coarsely", "thinly", "boneless", "skinless", "cooked",
        "uncooked", "plus", "more", "taste", "to", "of", "for", "the", "a", "an", "into", "cut", "or", "and",
        "as", "needed", "such", "preferably", "good", "quality", "extra", "firmly", "lightly", "heaping",
        "level", "rounded", "seeded", "pitted", "trimmed", "rinsed", "drained", "ripe"
    ]

    /// Regional and alternate names folded to one. Longest phrases first so
    /// "heavy whipping cream" is handled before "whipping cream".
    private static let synonyms: [(String, String)] = [
        ("bicarbonate of soda", "baking soda"),
        ("heavy whipping cream", "heavy cream"),
        ("confectioners sugar", "powdered sugar"),
        ("garbanzo bean", "chickpea"),
        ("coriander leaf", "cilantro"),
        ("whipping cream", "heavy cream"),
        ("spring onion", "green onion"),
        ("icing sugar", "powdered sugar"),
        ("caster sugar", "superfine sugar"),
        ("minced beef", "ground beef"),
        ("hamburger", "ground beef"),
        ("aubergine", "eggplant"),
        ("courgette", "zucchini"),
        ("capsicum", "bell pepper"),
        ("scallion", "green onion"),
        ("rocket", "arugula"),
        ("prawn", "shrimp")
    ]

    /// Phrases containing "and" that must not be split into two ingredients.
    private static let protectedPhrases: [(String, String)] = [
        ("half and half", "halfandhalf"),
        ("mac and cheese", "macandcheese")
    ]

    private static let irregularPlurals: [String: String] = [
        "leaves": "leaf", "loaves": "loaf", "halves": "half", "knives": "knife"
    ]

    private static let notPlural: Set<String> = [
        "molasses", "hummus", "couscous", "asparagus", "citrus", "swiss",
        "lemongrass", "watercress", "brussels", "grits", "series", "species"
    ]

    // MARK: - Public

    /// The searchable ingredient name(s) in one line. Usually one; "salt and
    /// pepper" gives two and "butter or margarine" gives both alternatives.
    static func terms(fromLine line: String) -> [String] {
        var s = line.lowercased()
        s = s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        for fraction in ["¼", "½", "¾", "⅓", "⅔", "⅛", "⅜", "⅝", "⅞"] {
            s = s.replacingOccurrences(of: fraction, with: " ")
        }
        // Everything after the first comma is preparation ("…, sifted").
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        for (phrase, token) in protectedPhrases {
            s = s.replacingOccurrences(of: phrase, with: token)
        }

        let separator = "\u{1}"
        let marked = s.replacingOccurrences(
            of: #"\s+(?:and|or)\s+|\s*&\s*|\s*/\s*"#,
            with: separator,
            options: .regularExpression
        )

        var result: [String] = []
        for piece in marked.components(separatedBy: separator) {
            var words = contentWords(piece, dropUnits: true)
            if words.isEmpty { words = contentWords(piece, dropUnits: false) }
            guard !words.isEmpty else { continue }
            var term = words.map(singular).joined(separator: " ")
            for (from, to) in synonyms {
                term = term.replacingOccurrences(of: #"\b\#(from)s?\b"#, with: to, options: .regularExpression)
            }
            term = term.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty && !result.contains(term) { result.append(term) }
        }
        return result
    }

    /// Words a person typed into the ingredient search, reduced the same way.
    static func terms(fromQuery query: String) -> [String] {
        terms(fromLine: query)
    }

    // MARK: - Internals

    private static func contentWords(_ piece: String, dropUnits: Bool) -> [String] {
        var text = piece
        for dash in ["-", "–", "—", "/"] { text = text.replacingOccurrences(of: dash, with: " ") }
        text = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")

        var words: [String] = []
        var current = ""
        func flush() {
            if let first = current.first, !first.isNumber, !noise.contains(current) {
                words.append(current)
            }
            current = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()

        guard dropUnits else { return words }
        var kept: [String] = []
        for (index, word) in words.enumerated() {
            if units.contains(word) && index < words.count - 1 { continue }
            kept.append(word)
        }
        return kept
    }

    static func singular(_ word: String) -> String {
        if notPlural.contains(word) { return word }
        if let irregular = irregularPlurals[word] { return irregular }
        if word.count <= 3 { return word }
        if word.hasSuffix("ies") && word.count > 4 { return String(word.dropLast(3)) + "y" }
        for suffix in ["oes", "ches", "shes", "xes", "sses", "zes"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("us") && !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }
}
