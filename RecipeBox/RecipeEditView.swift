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

    @State private var editMode: EditMode = .inactive
    @State private var keyboardVisible = false
    @State private var confirmSaveDiscardsOther = false
    @State private var confirmUndoDiscardsEdits = false
    @FocusState private var focusedID: UUID?
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editor mode", selection: modeBinding) {
                ForEach(EditorModel.Mode.allCases) { mode in
                    // A dot marks a view that has unsaved edits.
                    Text(model.isDirty(mode) ? "\(mode.rawValue) •" : mode.rawValue)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            controlBar

            switch model.mode {
            case .fields: fieldsEditor
            case .text: textEditor
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Self.hideKeyboard() }
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

    private var controlBar: some View {
        HStack(spacing: 12) {
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }

            if keyboardVisible {
                Button {
                    Self.hideKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
            }

            Spacer()

            if model.currentDirty {
                Text("Unsaved")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Revert") { model.revertCurrent() }
                .disabled(!model.currentDirty)

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
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Text mode

    private var textEditor: some View {
        TextEditor(text: $model.textDraft)
            .font(.body)
            .padding(12)
            .focused($textFocused)
            .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Fields mode

    private var fieldsEditor: some View {
        Form {
            titleSection
            detailsSection
            ingredientSections
            instructionSections
            tipsSection
            nutritionSection
            addSectionMenu
        }
        .environment(\.editMode, $editMode)
        // Dragging the list down hides the keyboard, wherever it is.
        .scrollDismissesKeyboard(.interactively)
    }

    private var titleSection: some View {
        Section {
            TextField("Recipe title", text: $model.fieldsDraft.title, axis: .vertical)
                .font(.headline)
        }
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

/// A list of single-line-or-wrapping text rows with add / delete / reorder.
/// Pressing Return inside a row starts a new row after it, and pasting
/// several lines splits them into separate rows.
private struct LineRows: View {
    @Binding var lines: [EditableLine]
    let placeholder: String
    let addTitle: String
    var numbered = false
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
                    .onChange(of: line.text) { newValue in
                        if newValue.contains("\n") { split(line.id, newValue) }
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
