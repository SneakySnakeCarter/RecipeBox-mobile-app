import SwiftUI

/// App-wide look. The accent color is applied once, at the root
/// (RecipeBoxApp), so every prominent button follows it. Change it here to
/// re-theme the whole app.
enum AppTheme {
    static let accent = Color.orange
}

/// The groups recipes are filed under on the main page.
enum RecipeCategory {
    /// Always shown on the main page, in this order, even when empty.
    static let defaults = ["Breakfast", "Lunch", "Dinner", "Dessert", "Snacks"]
    /// Label (never stored) for recipes with no category.
    static let uncategorized = "Uncategorized"

    /// A starting category worked out from the recipe's title, so most
    /// recipes land in the right place without any typing. Returns "" when
    /// nothing obvious fits — the person can set it in the editor.
    static func guess(fromTitle title: String) -> String {
        let t = " " + title.lowercased() + " "
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }

        // Savory "pies" and similar that look like desserts by name.
        if has(["pot pie", "shepherd", "cottage pie", "meat pie", "pork pie", "chicken pie", "pizza"]) {
            return ""
        }
        if has(["pancake", "waffle", "omelet", "omelette", "oatmeal", "granola", "french toast", "scramble",
                "frittata", "muffin", "breakfast", "crepe", "hash brown", "brunch", "bagel"]) {
            return "Breakfast"
        }
        if has([" pie ", " cake", "cookie", "brownie", "pudding", "cobbler", "fudge", "ice cream", "cupcake",
                " tart ", "custard", "cheesecake", "pumpkin bread", "banana bread", "zucchini bread",
                "crumble", "truffle", "mousse", "sorbet", "frosting", "caramel", "dessert", "pie "]) {
            return "Dessert"
        }
        if has(["sandwich", "panini", " wrap", " blt "]) {
            return "Lunch"
        }
        return ""
    }
}
