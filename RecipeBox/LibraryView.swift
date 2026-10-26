import SwiftUI

/// "My Recipes": every recipe saved to the database. Search by title, or by
/// ingredient — type what you have and see the recipes that use all of it,
/// then the closest matches (with what each one is missing).
struct LibraryView: View {
    private enum SearchMode: String, CaseIterable, Identifiable {
        case title = "Recipes"
        case ingredients = "By Ingredient"
        var id: String { rawValue }
    }

    @State private var mode: SearchMode = .title
    @State private var titleQuery = ""
    @State private var summaries: [RecipeSummary] = []

    // Ingredient search
    @State private var ingredientInput = ""
    @State private var ingredients: [String] = []
    @State private var matches: [IngredientMatch] = []
    @State private var isSearching = false
    @State private var searchedOnce = false

    // Opening a recipe
    @State private var isOpening = false
    @State private var opened: OpenedRecipe?
    @State private var openedRecipe = EditableRecipe()

    @State private var errorMessage: String?
    @State private var deleting: RecipeSummary?

    /// A saved recipe loaded and ready for the Compare screen.
    private struct OpenedRecipe: Identifiable, Hashable {
        let id: UUID
        let source: StitchedImage
        let regions: [CGRect]
        let info: LibraryInfo

        // Identified by the recipe alone (the images inside aren't Hashable).
        static func == (a: OpenedRecipe, b: OpenedRecipe) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var deleteTitle: String {
        let name = deleting?.title ?? ""
        return "Delete “\(name.isEmpty ? "Untitled recipe" : name)”?"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Search by", selection: $mode) {
                ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            switch mode {
            case .title: titleList
            case .ingredients: ingredientSearch
            }
        }
        .navigationTitle("My Recipes")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isOpening {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView("Opening…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .navigationDestination(item: $opened) { item in
            ComparePagerView(
                source: item.source,
                excludedRegions: item.regions,
                recipe: $openedRecipe,
                libraryInfo: item.info
            )
        }
        .onAppear { refresh() }
        .alert("My Recipes", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) {
                if let deleting { delete(deleting) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its pictures taken in the app are deleted too. Photos in your library are not touched.")
        }
    }

    // MARK: - Title list

    private var titleList: some View {
        List {
            Section {
                TextField("Search titles", text: $titleQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: titleQuery) { _, _ in refresh() }
            }
            if summaries.isEmpty {
                Section {
                    Text(titleQuery.isEmpty
                         ? "No saved recipes yet. Open a recipe and tap the bookmark to add it here."
                         : "No recipes match.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(summaries.count) recipe\(summaries.count == 1 ? "" : "s")") {
                    ForEach(summaries) { summary in
                        Button {
                            open(summary.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title.isEmpty ? "Untitled recipe" : summary.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(subtitle(for: summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                deleting = summary
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for summary: RecipeSummary) -> String {
        var parts = ["\(summary.ingredientCount) ingredient\(summary.ingredientCount == 1 ? "" : "s")"]
        if summary.photoCount > 0 {
            parts.append("\(summary.photoCount) picture\(summary.photoCount == 1 ? "" : "s")")
        }
        parts.append(summary.updatedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    // MARK: - Ingredient search

    private var ingredientSearch: some View {
        List {
            Section {
                HStack {
                    TextField("Add an ingredient, e.g. chicken", text: $ingredientInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { addIngredients() }
                    Button("Add") { addIngredients() }
                        .disabled(ingredientInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !ingredients.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(ingredients, id: \.self) { name in
                                Button {
                                    ingredients.removeAll { $0 == name }
                                    runSearch()
                                } label: {
                                    Label(name, systemImage: "xmark.circle.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.subheadline)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.orange.opacity(0.18), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } footer: {
                Text("Add each ingredient, separated by commas or one at a time. Spelling and wording don't have to be exact: “scallion” finds “green onions”, “tomato” finds “cherry tomatoes”.")
            }

            if isSearching {
                Section { ProgressView() }
            } else if ingredients.isEmpty {
                EmptyView()
            } else if matches.isEmpty && searchedOnce {
                Section { Text("No saved recipe has any of those.").foregroundStyle(.secondary) }
            } else {
                let complete = matches.filter(\.isComplete)
                let close = matches.filter { !$0.isComplete }
                if !complete.isEmpty {
                    Section("Has everything (\(complete.count))") {
                        ForEach(complete) { matchRow($0) }
                    }
                }
                if !close.isEmpty {
                    Section("Closest matches (\(close.count))") {
                        ForEach(close) { matchRow($0) }
                    }
                }
            }
        }
    }

    private func matchRow(_ match: IngredientMatch) -> some View {
        Button {
            open(match.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title.isEmpty ? "Untitled recipe" : match.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if match.isComplete {
                    Text("Has all \(ingredients.count) you searched")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Missing: " + match.missing.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(match.matches
                    .map { "\($0.query) → \($0.ingredientText)" }
                    .joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private func addIngredients() {
        let additions = ingredientInput
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !ingredients.contains($0) }
        ingredientInput = ""
        guard !additions.isEmpty else { return }
        ingredients.append(contentsOf: additions)
        runSearch()
    }

    private func runSearch() {
        // Each chip may reduce to more than one name ("salt and pepper").
        let terms = ingredients.flatMap { IngredientNormalizer.terms(fromQuery: $0) }
        guard !terms.isEmpty else {
            matches = []
            isSearching = false
            searchedOnce = false
            return
        }
        isSearching = true
        RecipeLibrary.shared.searchByIngredients(terms: terms) { result in
            isSearching = false
            searchedOnce = true
            switch result {
            case .success(let found): matches = found
            case .failure(let error):
                matches = []
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Loading, opening, deleting

    private func refresh() {
        do {
            summaries = try RecipeLibrary.shared.summaries(titleContains: titleQuery)
        } catch {
            errorMessage = error.localizedDescription
        }
        if mode == .ingredients || !ingredients.isEmpty { runSearch() }
    }

    private func open(_ id: UUID) {
        guard !isOpening else { return }
        do {
            guard let record = try RecipeLibrary.shared.load(id: id) else {
                errorMessage = "That recipe couldn't be found."
                refresh()
                return
            }
            isOpening = true
            SourceLoader.load(refs: record.sourceRefs, removeOverlap: record.removeOverlap) { stitched in
                isOpening = false
                // No stored photo (pasted text, or the photo is gone): show
                // the recipe's own text where the original would be.
                let source = stitched ?? TextCardRenderer.render(record.sourceText ?? record.recipe.toText())
                openedRecipe = record.recipe
                opened = OpenedRecipe(
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

    private func delete(_ summary: RecipeSummary) {
        do {
            try RecipeLibrary.shared.delete(id: summary.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
