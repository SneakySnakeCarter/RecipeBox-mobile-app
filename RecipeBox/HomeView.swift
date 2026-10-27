import SwiftUI

/// The main page: saved recipes grouped by type (Breakfast, Dinner,
/// Dessert…). Tap a type to open or close its list; tap a recipe to open it
/// in the editor. "Add Recipe" goes to the input page (ContentView).
struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var opener = RecipeOpener()

    @State private var summaries: [RecipeSummary] = []
    @State private var expanded: Set<String> = []
    @State private var showAdd = false
    @State private var showSearch = false
    @State private var showSettings = false
    /// True while this page is the one showing (not a page pushed on top).
    @State private var atRoot = true
    @State private var deleting: RecipeSummary?
    @State private var errorMessage: String?

    private struct CategoryGroup: Identifiable {
        let name: String
        let recipes: [RecipeSummary]
        var id: String { name }
    }

    /// The default types (always shown, even when empty), then any custom
    /// types in use, then "Uncategorized" if there are recipes without one.
    private var groups: [CategoryGroup] {
        var buckets: [String: [RecipeSummary]] = [:]
        var custom: [String] = []
        var uncategorized: [RecipeSummary] = []
        let defaultKeys = Set(RecipeCategory.defaults.map { $0.lowercased() })

        for recipe in summaries {
            let name = recipe.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                uncategorized.append(recipe)
                continue
            }
            let key = name.lowercased()
            if !defaultKeys.contains(key) && buckets[key] == nil { custom.append(name) }
            buckets[key, default: []].append(recipe)
        }

        let customSorted = custom.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result = (RecipeCategory.defaults + customSorted).map {
            CategoryGroup(name: $0, recipes: buckets[$0.lowercased()] ?? [])
        }
        if !uncategorized.isEmpty {
            result.append(CategoryGroup(name: RecipeCategory.uncategorized, recipes: uncategorized))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded: expansion(for: group.name)) {
                            if group.recipes.isEmpty {
                                Text("No recipes yet")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(group.recipes) { recipe in
                                    recipeRow(recipe)
                                }
                            }
                        } label: {
                            HStack {
                                Text(group.name)
                                    .font(.title3)
                                Spacer()
                                Text("\(group.recipes.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Recipes")
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text("\(summaries.count) recipe\(summaries.count == 1 ? "" : "s")")
                            .font(.subheadline)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
            .navigationTitle("RecipeBox")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Recipe", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search recipes")
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showAdd) { ContentView() }
            .navigationDestination(isPresented: $showSearch) { LibraryView() }
            .recipeOpening(opener)
            .sheet(isPresented: $showSettings) { SettingsView() }
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
                Text("Its pictures are deleted too. Photos in your photo library are not touched.")
            }
            .alert("My Recipes", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                atRoot = true
                refresh()
            }
            .onDisappear { atRoot = false }
            // Something was shared to RecipeBox: go to the Add Recipe page,
            // which picks it up.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { openAddPageIfSharedItemsWaiting() }
            }
            .helpDrawer(.home)
        }
    }

    // MARK: - Rows

    private func recipeRow(_ recipe: RecipeSummary) -> some View {
        Button {
            opener.open(recipe.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title.isEmpty ? "Untitled recipe" : recipe.title)
                    .foregroundStyle(.primary)
                Text(subtitle(for: recipe))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                deleting = recipe
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(for recipe: RecipeSummary) -> String {
        var parts = ["\(recipe.ingredientCount) ingredient\(recipe.ingredientCount == 1 ? "" : "s")"]
        if recipe.photoCount > 0 {
            parts.append("\(recipe.photoCount) picture\(recipe.photoCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var deleteTitle: String {
        let name = deleting?.title ?? ""
        return "Delete “\(name.isEmpty ? "Untitled recipe" : name)”?"
    }

    // MARK: - Actions

    private func expansion(for name: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(name) },
            set: { isOpen in
                if isOpen { expanded.insert(name) } else { expanded.remove(name) }
            }
        )
    }

    private func refresh() {
        do {
            summaries = try RecipeLibrary.shared.summaries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ recipe: RecipeSummary) {
        do {
            try RecipeLibrary.shared.delete(id: recipe.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openAddPageIfSharedItemsWaiting() {
        guard atRoot, !showAdd, !SharedInbox.pendingBatches().isEmpty else { return }
        showAdd = true
    }
}

#Preview {
    HomeView()
}
