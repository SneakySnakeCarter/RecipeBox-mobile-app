import SwiftUI
import UIKit

/// Which page's help to show.
enum HelpTopic {
    case home, addRecipe, joinPhotos, blockOut, compare, search

    var title: String {
        switch self {
        case .home: return "My Recipes"
        case .addRecipe: return "Adding a recipe"
        case .joinPhotos: return "Joining photos"
        case .blockOut: return "Blocking out areas"
        case .compare: return "Editing a recipe"
        case .search: return "Searching"
        }
    }

    /// Short help items: (heading, text).
    var items: [(String, String)] {
        switch self {
        case .home:
            return [
                ("Recipes by type", "Tap a type (Breakfast, Dinner…) to open or close its list. Tap a recipe to open it and edit it."),
                ("Rename or delete a type", "Press and hold a type's name for Rename Group or Delete Group. Deleting a group keeps its recipes; they move to Uncategorized."),
                ("Reorder types", "Tap Reorder, drag the handles to rearrange the types, then tap Done. Use Add group there to make a new type."),
                ("Add Recipe", "Starts a new recipe from photos, a screenshot, shared text, or pasted text."),
                ("Search", "The magnifier searches by title, or by ingredient: type what you have and see recipes that use all of it, then the closest matches."),
                ("Delete", "Swipe a recipe left to delete it."),
                ("Changing a recipe's type", "Open the recipe and use the Category row in the editor.")
            ]
        case .addRecipe:
            return [
                ("Add Recipe Photos", "Take photos with the camera or choose up to 10 from your library. Several photos are joined into one tall image."),
                ("Paste Recipe Text", "Paste or type the recipe text. It is read directly, with no photo."),
                ("From other apps", "Use the iOS Share button in Photos, Safari or Notes and choose RecipeBox. Shared items are picked up when you open the app."),
                ("AI engine", "The pill shows which engine reads recipes. Tap it, or the gear, to change the engine or API key.")
            ]
        case .joinPhotos:
            return [
                ("Order", "Drag the handles to reorder photos, or swipe one to remove it. They are joined top to bottom in this order."),
                ("Remove overlapping areas", "For screenshots of a scrolling page, cuts the repeated rows where one screenshot overlaps the next."),
                ("Stitch", "Joins the photos into one image and goes to the next step.")
            ]
        case .blockOut:
            return [
                ("Block out areas", "Drag a box over anything that shouldn't be read, such as another recipe's text or an app's buttons. Tap a box to remove it."),
                ("Tall images", "For several joined photos, use Scroll to look around and Draw boxes to draw."),
                ("Continue", "Reads the recipe. Blocked areas are skipped.")
            ]
        case .compare:
            return [
                ("Compare", "Swipe between the recipe and the original photo. In landscape they sit side by side; drag the bar between them to resize."),
                ("Fields and Text", "Fields edits each ingredient and step in its own row. Text edits everything as one block. Each has its own unsaved edits."),
                ("Save, Revert, Undo", "Save keeps your edits. Revert drops unsaved edits in the current view. Undo Last Save (⋯ menu) steps back."),
                ("Bookmark", "Adds the recipe to My Recipes. After that, every Save is stored automatically."),
                ("Category", "Choose where the recipe is filed on the main page."),
                ("Pictures", "Add up to 10 pictures at the bottom of Fields and tie each to an ingredient, a step, or the whole recipe."),
                ("Re-read", "Has the AI read the original photo directly. It replaces unsaved text but keeps your pictures.")
            ]
        case .search:
            return [
                ("Recipes", "Search recipe titles."),
                ("By Ingredient", "Add ingredients one at a time or separated by commas. Recipes with everything are listed first, then the closest matches with what each is missing."),
                ("Wording", "It doesn't have to match exactly: “scallion” finds “green onions”, “tomato” finds “cherry tomatoes”.")
            ]
        }
    }
}

/// A caret pinned to the bottom of a page. Tap it and a help panel for that
/// page slides up; tap again to close. Hidden while the keyboard is showing
/// (and when `hidden`, e.g. in landscape where height is precious).
private struct HelpDrawerModifier: ViewModifier {
    let topic: HelpTopic
    let hidden: Bool

    @State private var expanded = false
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !hidden && !keyboardUp {
                    drawer
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                VStack(spacing: 2) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 40, height: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide help" : "Show help")

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(topic.title)
                            .font(.headline)
                        ForEach(Array(topic.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0).font(.subheadline.weight(.semibold))
                                Text(item.1)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension View {
    /// Adds the bottom help caret for `topic` to this page.
    func helpDrawer(_ topic: HelpTopic, hidden: Bool = false) -> some View {
        modifier(HelpDrawerModifier(topic: topic, hidden: hidden))
    }
}
