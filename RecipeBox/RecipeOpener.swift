import SwiftUI

/// A saved recipe, loaded and ready for the Compare screen.
struct OpenedRecipe: Identifiable, Hashable {
    let id: UUID
    let source: StitchedImage
    let regions: [CGRect]
    let info: LibraryInfo

    // Identified by the recipe alone (the images inside aren't Hashable).
    static func == (a: OpenedRecipe, b: OpenedRecipe) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Opens a saved recipe from the database: reads it, reloads its original
/// photo(s), then pushes the Compare screen. Shared by the main page and the
/// search page.
final class RecipeOpener: ObservableObject {
    @Published var opened: OpenedRecipe?
    @Published var isOpening = false
    @Published var errorMessage: String?
    /// The recipe the Compare screen edits (it works through a binding).
    @Published var recipe = EditableRecipe()

    func open(_ id: UUID) {
        guard !isOpening else { return }
        do {
            guard let record = try RecipeLibrary.shared.load(id: id) else {
                errorMessage = "That recipe couldn't be found."
                return
            }
            isOpening = true
            SourceLoader.load(refs: record.sourceRefs, removeOverlap: record.removeOverlap) { [weak self] stitched in
                guard let self else { return }
                self.isOpening = false
                // No stored photo (pasted text, or the photo is gone): show
                // the recipe's own text where the original would be.
                let source = stitched ?? TextCardRenderer.render(record.sourceText ?? record.recipe.toText())
                self.recipe = record.recipe
                self.opened = OpenedRecipe(
                    id: id,
                    source: source,
                    regions: stitched == nil ? [] : record.excludedRegions,
                    info: LibraryInfo(
                        id: id,
                        sourceRefs: record.sourceRefs,
                        sourceText: record.sourceText,
                        removeOverlap: record.removeOverlap,
                        isSaved: true
                    )
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecipeOpeningModifier: ViewModifier {
    @ObservedObject var opener: RecipeOpener

    func body(content: Content) -> some View {
        content
            .overlay {
                if opener.isOpening {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Opening…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .navigationDestination(item: $opener.opened) { item in
                ComparePagerView(
                    source: item.source,
                    excludedRegions: item.regions,
                    recipe: $opener.recipe,
                    libraryInfo: item.info
                )
            }
            .alert("Couldn't open the recipe", isPresented: Binding(
                get: { opener.errorMessage != nil },
                set: { if !$0 { opener.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(opener.errorMessage ?? "")
            }
    }
}

extension View {
    /// Shows the opening spinner and pushes the Compare screen when
    /// `opener.open(_:)` finishes.
    func recipeOpening(_ opener: RecipeOpener) -> some View {
        modifier(RecipeOpeningModifier(opener: opener))
    }
}
