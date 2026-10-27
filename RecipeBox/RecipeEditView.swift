import SwiftUI
import UIKit

/// Structured recipe editor. "Fields" mode is a form with one row per
/// ingredient / step / tip; "Text" mode is a single big text box for bulk
/// edits. The two views are independent drafts: nothing reaches the saved
/// recipe until Save is tapped, and Revert / Undo Last Save are available
/// (see EditorModel).
///
/// This view scrolls on its own, so the length of the recipe never affects
/// the photo next to it.
struct RecipeEditView: View {
    @ObservedObject var model: EditorModel
    /// Landscape: collapse the mode switch and the Save / Revert controls
    /// into one thin row (the screen's nav bar is hidden there, so the back
    /// button and AI-undo move into this row too).
    var compact = false
    var onBack: (() -> Void)?
    var onUndoAIReread: (() -> Void)?
    /// Landscape only (portrait has the bookmark in the nav bar): add the
    /// recipe to My Recipes.
    var inLibrary = false
    var onLibrary: (() -> Void)?

    @State private var editMode: EditMode = .inactive
    @State private var keyboardVisible = false
    @State private var confirmSaveDiscardsOther = false
    @State private var confirmUndoDiscardsEdits = false
    /// Categories already used by saved recipes, for the Category menu.
    @State private var knownCategories: [String] = []
    @State private var showNewCategory = false
    @State private var newCategoryName = ""
    @FocusState private var focusedID: UUID?
    @FocusState private var textFocused: Bool

    init(
        model: EditorModel,
        compact: Bool = false,
        onBack: (() -> Void)? = nil,
        onUndoAIReread: (() -> Void)? = nil,
        inLibrary: Bool = false,
        onLibrary: (() -> Void)? = nil
    ) {
        self.model = model
        self.compact = compact
        self.onBack = onBack
        self.onUndoAIReread = onUndoAIReread
        self.inLibrary = inLibrary
        self.onLibrary = onLibrary
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                compactBar
            } else {
                modePicker
                    .padding(.horizontal)
                    .padding(.top, 8)
                controlBar
            }

            switch model.mode {
            case .fields: fieldsEditor
            case .text: textEditor
            }
        }
        .toolbar {
            // Landscape has no height to spare: skip the extra keyboard row
            // (its thin top bar already has a hide-keyboard button).
            if !compact {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { Self.hideKeyboard() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .alert("Discard edits in the other view?", isPresented: $confirmSaveDiscardsOther) {
            Button("Save and Discard", role: .destructive) {
                Self.hideKeyboard()
                model.saveCurrent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(model.mode == .fields ? "Text" : "Fields") view has unsaved edits. Saving here replaces them.")
        }
        .alert("Undo the last save?", isPresented: $confirmUndoDiscardsEdits) {
            Button("Undo Save", role: .destructive) { model.undoLastSave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You also have unsaved edits, which will be discarded.")
        }
    }

    /// Dismisses the keyboard whichever field has it — including the title
    /// and details fields, which aren't tracked by `focusedID`.
    private static func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private var modeBinding: Binding<EditorModel.Mode> {
        Binding(
            get: { model.mode },
            set: { newMode in
                Self.hideKeyboard()
                focusedID = nil
                textFocused = false
                editMode = .inactive
                model.mode = newMode
            }
        )
    }

    // MARK: - Save / revert bar

    private var modePicker: some View {
        Picker("Editor mode", selection: modeBinding) {
            ForEach(EditorModel.Mode.allCases) { mode in
                // A dot marks a view that has unsaved edits.
                Text(model.isDirty(mode) ? "\(mode.rawValue) •" : mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var moreMenu: some View {
        Menu {
            if model.mode == .fields {
                Button {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    Label(
                        editMode.isEditing ? "Done Reordering" : "Reorder / Delete Rows",
                        systemImage: "arrow.up.arrow.down"
                    )
                }
            }
            Button {
                if model.hasUnsavedEdits {
                    confirmUndoDiscardsEdits = true
                } else {
                    model.undoLastSave()
                }
            } label: {
                Label("Undo Last Save", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndoSave)
            if let onUndoAIReread {
                Button(action: onUndoAIReread) {
                    Label("Undo AI Re-read", systemImage: "eye.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var hideKeyboardButton: some View {
        Button {
            Self.hideKeyboard()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
        }
    }

    private var revertButton: some View {
        Button("Revert") { model.revertCurrent() }
            .disabled(!model.currentDirty)
    }

    private var saveButton: some View {
        Button("Save") {
            if model.otherDirty {
                confirmSaveDiscardsOther = true
            } else {
                Self.hideKeyboard()
                model.saveCurrent()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!model.currentDirty)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            moreMenu

            if keyboardVisible { hideKeyboardButton }

            Spacer()

            if model.currentDirty {
                Text("Unsaved")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            revertButton
            saveButton
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// One thin row for landscape: back, mode switch, ⋯, then Revert / Save.
    private var compactBar: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
            }

            modePicker
                .controlSize(.small)
                .frame(maxWidth: 170)

            moreMenu

            if let onLibrary {
                Button(action: onLibrary) {
                    Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
                }
            }

            if keyboardVisible { hideKeyboardButton }

            Spacer(minLength: 0)

            revertButton
            saveButton
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    // MARK: - Text mode

    private var textEditor: some View {
        TextEditor(text: $model.textDraft)
            .font(.body)
            .padding(compact ? 6 : 12)
            .focused($textFocused)
            .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Fields mode

    private var fieldsEditor: some View {
        Form {
            titleSection
            categorySection
            detailsSection
            ingredientSections
            instructionSections
            tipsSection
            nutritionSection
            RecipePhotosSection(recipe: $model.fieldsDraft)
            addSectionMenu
        }
        .environment(\.editMode, $editMode)
        .onAppear { knownCategories = RecipeLibrary.shared.categoryNames() }
        .alert("New category", isPresented: $showNewCategory) {
            TextField("Name, e.g. Soups", text: $newCategoryName)
            Button("Add") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { model.fieldsDraft.category = name }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Landscape: tighter rows and section gaps so more fits above the keyboard.
        .environment(\.defaultMinListRowHeight, compact ? 32 : 44)
        .listSectionSpacing(compact ? .compact : .default)
        // Dragging the list down hides the keyboard, wherever it is.
        .scrollDismissesKeyboard(.interactively)
    }

    private var titleSection: some View {
        Section {
            TextField("Recipe title", text: $model.fieldsDraft.title, axis: .vertical)
                .font(.headline)
        }
    }

    /// Where the recipe is filed on the main page.
    private var categorySection: some View {
        Section {
            Picker("Category", selection: $model.fieldsDraft.category) {
                Text("None").tag("")
                ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Button {
                newCategoryName = ""
                showNewCategory = true
            } label: {
                Label("New category…", systemImage: "plus.circle")
            }
        }
    }

    private var categoryOptions: [String] {
        var names = RecipeCategory.defaults
        for name in knownCategories + [model.fieldsDraft.category] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                names.append(trimmed)
            }
        }
        return names
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details", isExpanded: $model.showDetails) {
                TextField(
                    "Servings, times, description, source…",
                    text: $model.fieldsDraft.details,
                    axis: .vertical
                )
                .lineLimit(3...)
            }
        } footer: {
            if model.showDetails {
                Text("One per line, e.g. “Servings: 4”, “Prep: 20 min”, “Cook: 30 min”, “Source: Grandma”. Any other line is saved as the description.")
            }
        }
    }

    private var ingredientSections: some View {
        Group {
            ForEach($model.fieldsDraft.ingredientGroups) { $group in
                Section {
                    LineRows(
                        lines: $group.lines,
                        placeholder: "Ingredient",
                        addTitle: "Add ingredient",
                        photoCounts: photoCounts(for: .ingredient),
                        focusedID: $focusedID
                    )
                } header: {
                    groupHeader(
                        title: group.id == model.fieldsDraft.ingredientGroups.first?.id ? "Ingredients" : nil,
                        name: $group.name,
                        showsGroupControls: model.ingredientGroupsEnabled,
                        canRemove: model.fieldsDraft.ingredientGroups.count > 1,
                        remove: { model.fieldsDraft.ingredientGroups.removeAll { $0.id == group.id } }
                    )
                }
            }
            if model.ingredientGroupsEnabled {
                Section {
                    Button {
                        model.fieldsDraft.ingredientGroups.append(EditableGroup())
                    } label: {
                        Label("Add ingredient group", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    private var instructionSections: some View {
        Group {
            ForEach($model.fieldsDraft.instructionGroups) { $group in
                Section {
                    LineRows(
                        lines: $group.lines,
                        placeholder: "Step",
                        addTitle: "Add step",
                        numbered: true,
                        photoCounts: photoCounts(for: .step),
                        focusedID: $focusedID
                    )
                } header: {
                    groupHeader(
                        title: group.id == model.fieldsDraft.instructionGroups.first?.id ? "Instructions" : nil,
                        name: $group.name,
                        showsGroupControls: model.instructionGroupsEnabled,
                        canRemove: model.fieldsDraft.instructionGroups.count > 1,
                        remove: { model.fieldsDraft.instructionGroups.removeAll { $0.id == group.id } }
                    )
                }
            }
            if model.instructionGroupsEnabled {
                Section {
                    Button {
                        model.fieldsDraft.instructionGroups.append(EditableGroup())
                    } label: {
                        Label("Add instruction group", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tipsSection: some View {
        if !model.fieldsDraft.tips.isEmpty {
            Section("Tips") {
                LineRows(
                    lines: $model.fieldsDraft.tips,
                    placeholder: "Tip",
                    addTitle: "Add tip",
                    focusedID: $focusedID
                )
            }
        }
    }

    @ViewBuilder
    private var nutritionSection: some View {
        if !model.fieldsDraft.nutrition.isEmpty {
            Section("Nutrition (per serving)") {
                ForEach($model.fieldsDraft.nutrition) { $fact in
                    HStack {
                        TextField("Label", text: $fact.label)
                        TextField("Value", text: $fact.value)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .onDelete { model.fieldsDraft.nutrition.remove(atOffsets: $0) }
                .onMove { model.fieldsDraft.nutrition.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    model.fieldsDraft.nutrition.append(EditableFact())
                } label: {
                    Label("Add nutrition fact", systemImage: "plus.circle")
                }
            }
        }
    }

    private var addSectionMenu: some View {
        Section {
            Menu {
                Button("Tip") {
                    let tip = EditableLine()
                    model.fieldsDraft.tips.append(tip)
                    DispatchQueue.main.async { focusedID = tip.id }
                }
                Button("Nutrition fact") { model.fieldsDraft.nutrition.append(EditableFact()) }
            } label: {
                Label("Add section…", systemImage: "plus")
            }
        }
    }

    /// How many pictures are tied to each ingredient / step row, for the
    /// little photo badge on those rows.
    private func photoCounts(for kind: PhotoRowKind) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for photo in model.fieldsDraft.photos {
            switch (kind, photo.attachment) {
            case (.ingredient, .ingredient(let id)), (.step, .step(let id)):
                counts[id, default: 0] += 1
            default:
                break
            }
        }
        return counts
    }

    private func groupHeader(
        title: String?,
        name: Binding<String>,
        showsGroupControls: Bool,
        canRemove: Bool,
        remove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.headline)
            }
            if showsGroupControls {
                HStack {
                    TextField("Group name (optional)", text: name)
                        .font(.subheadline)
                    if canRemove {
                        Button(role: .destructive, action: remove) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

private enum PhotoRowKind { case ingredient, step }

/// A list of single-line-or-wrapping text rows with add / delete / reorder.
/// Pressing Return inside a row starts a new row after it, and pasting
/// several lines splits them into separate rows.
private struct LineRows: View {
    @Binding var lines: [EditableLine]
    let placeholder: String
    let addTitle: String
    var numbered = false
    var photoCounts: [UUID: Int] = [:]
    @FocusState.Binding var focusedID: UUID?

    var body: some View {
        ForEach($lines) { $line in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if numbered {
                    Text("\(number(of: line.id)).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                TextField(placeholder, text: $line.text, axis: .vertical)
                    .lineLimit(1...)
                    .focused($focusedID, equals: line.id)
                    .onChange(of: line.text) { _, newValue in
                        if newValue.contains("\n") { split(line.id, newValue) }
                    }
                if let count = photoCounts[line.id] {
                    Label("\(count)", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .onDelete { lines.remove(atOffsets: $0) }
        .onMove { lines.move(fromOffsets: $0, toOffset: $1) }

        Button {
            let row = EditableLine()
            lines.append(row)
            DispatchQueue.main.async { focusedID = row.id }
        } label: {
            Label(addTitle, systemImage: "plus.circle")
        }
    }

    private func number(of id: UUID) -> Int {
        (lines.firstIndex { $0.id == id } ?? 0) + 1
    }

    /// A newline typed or pasted into a row: keep the text before it in
    /// that row and move everything after it into new rows below.
    private func split(_ id: UUID, _ text: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        var parts = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let first = parts.removeFirst()

        // Keep a trailing blank piece (Return at the end of a row opens a
        // fresh row to type in) but drop blank pieces in the middle.
        var rest: [String] = []
        for (i, part) in parts.enumerated() where !part.isEmpty || i == parts.count - 1 {
            rest.append(part)
        }

        lines[index].text = first
        let newRows = rest.map { EditableLine($0) }
        lines.insert(contentsOf: newRows, at: index + 1)
        if let last = newRows.last {
            DispatchQueue.main.async { focusedID = last.id }
        }
    }
}
