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

    // Groups: order, renaming, adding, deleting
    /// The groups in the order the person arranged them.
    @State private var categoryOrder: [String] = []
    @State private var isReordering = false
    @State private var renamingGroup: String?
    @State private var renameText = ""
    @State private var showNewGroup = false
    @State private var newGroupText = ""
    @State private var deletingGroup: String?

    private struct CategoryGroup: Identifiable {
        let name: String
        let recipes: [RecipeSummary]
        var id: String { name }
    }

    /// The default types (always shown, even when empty), then any custom
    /// types in use, then "Uncategorized" if there are recipes without one.
    private var groups: [CategoryGroup] {
        var buckets: [String: [RecipeSummary]] = [:]
        var unknown: [String] = []
        var uncategorized: [RecipeSummary] = []
        let knownKeys = Set(categoryOrder.map { $0.lowercased() })

        for recipe in summaries {
            let name = recipe.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                uncategorized.append(recipe)
                continue
            }
            let key = name.lowercased()
            // Defensive: a recipe filed under a group missing from the list.
            if !knownKeys.contains(key) && buckets[key] == nil { unknown.append(name) }
            buckets[key, default: []].append(recipe)
        }

        let extra = unknown.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result = (categoryOrder + extra).map {
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
                    if isReordering {
                        // Plain rows with drag handles; groups collapse so
                        // a whole group moves as one line.
                        ForEach(categoryOrder, id: \.self) { name in
                            HStack {
                                Text(name).font(.title3)
                                Spacer()
                                Text("\(count(in: name))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onMove { source, destination in
                            categoryOrder.move(fromOffsets: source, toOffset: destination)
                            saveOrder()
                        }

                        Button {
                            newGroupText = ""
                            showNewGroup = true
                        } label: {
                            Label("Add group", systemImage: "plus.circle")
                        }
                    } else {
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
                                groupLabel(group)
                            }
                        }
                    }
                } header: {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My Recipes")
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                            Text("\(summaries.count) recipe\(summaries.count == 1 ? "" : "s")")
                                .font(.subheadline)
                        }
                        Spacer()
                        Button(isReordering ? "Done" : "Reorder") {
                            withAnimation { isReordering.toggle() }
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
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
            .alert("Rename group", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renamingGroup = nil }
            } message: {
                Text("Recipes in this group move to the new name.")
            }
            .alert("New group", isPresented: $showNewGroup) {
                TextField("Name, e.g. Soups", text: $newGroupText)
                Button("Add") { commitNewGroup() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete the group “\(deletingGroup ?? "")”?",
                isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    if let name = deletingGroup { deleteGroup(name) }
                    deletingGroup = nil
                }
                Button("Cancel", role: .cancel) { deletingGroup = nil }
            } message: {
                Text("Its recipes are not deleted; they move to Uncategorized.")
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

    // MARK: - Groups

    /// A group's name row. Long-press it for Rename / Delete. Uncategorized
    /// is not a real group, so it has no menu.
    @ViewBuilder
    private func groupLabel(_ group: CategoryGroup) -> some View {
        let row = HStack {
            Text(group.name)
                .font(.title3)
            Spacer()
            Text("\(group.recipes.count)")
                .foregroundStyle(.secondary)
        }
        if group.name == RecipeCategory.uncategorized {
            row
        } else {
            row.contextMenu {
                Button {
                    renameText = group.name
                    renamingGroup = group.name
                } label: {
                    Label("Rename Group", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deletingGroup = group.name
                } label: {
                    Label("Delete Group", systemImage: "trash")
                }
            }
        }
    }

    private func count(in name: String) -> Int {
        summaries.filter { $0.category.caseInsensitiveCompare(name) == .orderedSame }.count
    }

    private func saveOrder() {
        do {
            try RecipeLibrary.shared.setCategoryOrder(categoryOrder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let old = renamingGroup else { return }
        renamingGroup = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        do {
            try RecipeLibrary.shared.renameCategory(from: old, to: name)
            // Keep the group open if it was open.
            if expanded.remove(old) != nil { expanded.insert(name) }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitNewGroup() {
        let name = newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name.caseInsensitiveCompare(RecipeCategory.uncategorized) == .orderedSame
            || categoryOrder.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            errorMessage = "There is already a group named “\(name)”."
            return
        }
        do {
            try RecipeLibrary.shared.addCategory(name)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteGroup(_ name: String) {
        do {
            try RecipeLibrary.shared.deleteCategory(name)
            expanded.remove(name)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
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
            categoryOrder = RecipeLibrary.shared.categories()
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
