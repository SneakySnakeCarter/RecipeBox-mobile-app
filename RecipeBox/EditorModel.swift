import Foundation
import Combine

/// State behind the recipe editor, kept in an object owned by
/// ComparePagerView (not in RecipeEditView's own @State) so it survives the
/// editor being rebuilt — e.g. when the screen rotates between the swipe
/// layout and the side-by-side layout.
///
/// The model separates three things:
/// - `saved`: the committed recipe. Only Save (or an AI re-read / undo)
///   changes it.
/// - `fieldsDraft`: what the Fields view is editing.
/// - `textDraft`: what the Text view is editing.
///
/// The two drafts do not feed each other. Each starts as a copy of
/// `saved`, edits stay in its own draft until Save, and Revert simply
/// copies `saved` back over it. Saving always writes the *current* view's
/// draft into `saved`, then refreshes both drafts from it. Each save pushes
/// the previous `saved` onto `history`, which is what "Undo Last Save" uses.
final class EditorModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case fields = "Fields"
        case text = "Text"
        var id: String { rawValue }
    }

    @Published private(set) var saved: EditableRecipe
    @Published var fieldsDraft: EditableRecipe
    @Published var textDraft: String
    /// What `textDraft` looked like when last synced; differs => text edits.
    @Published private(set) var textBaseline: String
    @Published private(set) var history: [EditableRecipe] = []

    @Published var mode: Mode = .fields
    /// Details (servings, times, description, source) start collapsed.
    @Published var showDetails = false
    /// Whether to show group names / add-group controls. Decided from the
    /// recipe itself: only a recipe that already has named or multiple
    /// groups (e.g. Vinaigrette + Salad) gets them; see `looksGrouped`.
    @Published var ingredientGroupsEnabled: Bool
    @Published var instructionGroupsEnabled: Bool

    private let maxHistory = 20

    init(saved: EditableRecipe) {
        self.saved = saved
        self.fieldsDraft = saved
        let text = saved.toText()
        self.textDraft = text
        self.textBaseline = text
        self.ingredientGroupsEnabled = Self.looksGrouped(saved.ingredientGroups)
        self.instructionGroupsEnabled = Self.looksGrouped(saved.instructionGroups)
    }

    // MARK: - Dirty state

    var fieldsDirty: Bool { fieldsDraft != saved }
    var textDirty: Bool { textDraft != textBaseline }
    var currentDirty: Bool { mode == .fields ? fieldsDirty : textDirty }
    var otherDirty: Bool { mode == .fields ? textDirty : fieldsDirty }
    var hasUnsavedEdits: Bool { fieldsDirty || textDirty }
    var canUndoSave: Bool { !history.isEmpty }

    func isDirty(_ mode: Mode) -> Bool { mode == .fields ? fieldsDirty : textDirty }

    // MARK: - Actions

    /// Commits the current view's draft. Trims text and drops empty rows
    /// (via StructuredRecipe), then refreshes both drafts from the result.
    func saveCurrent() {
        let candidate: EditableRecipe
        switch mode {
        case .fields:
            candidate = EditableRecipe(from: fieldsDraft.toStructured())
        case .text:
            candidate = EditableRecipe(from: EditableRecipe.parse(text: textDraft).toStructured())
        }
        // Only record an undo step if something actually changed.
        if candidate.toText() != saved.toText() {
            history.append(saved)
            if history.count > maxHistory { history.removeFirst() }
        }
        saved = candidate
        syncDrafts()
    }

    /// Throws away unsaved edits in the current view only.
    func revertCurrent() {
        switch mode {
        case .fields:
            fieldsDraft = saved
            updateGroupFlags()
        case .text:
            textDraft = textBaseline
        }
    }

    /// Restores the recipe as it was before the last save (discarding any
    /// unsaved edits in both views).
    func undoLastSave() {
        guard let previous = history.popLast() else { return }
        saved = previous
        syncDrafts()
    }

    /// Replaces the saved recipe from outside the editor (an AI re-read or
    /// its undo). Clears save history and both drafts.
    func reset(to recipe: EditableRecipe) {
        saved = recipe
        history = []
        syncDrafts()
    }

    // MARK: - Helpers

    private func syncDrafts() {
        fieldsDraft = saved
        let text = saved.toText()
        textDraft = text
        textBaseline = text
        updateGroupFlags()
    }

    private func updateGroupFlags() {
        ingredientGroupsEnabled = Self.looksGrouped(fieldsDraft.ingredientGroups)
        instructionGroupsEnabled = Self.looksGrouped(fieldsDraft.instructionGroups)
    }

    private static func looksGrouped(_ groups: [EditableGroup]) -> Bool {
        groups.count > 1 || groups.contains {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
