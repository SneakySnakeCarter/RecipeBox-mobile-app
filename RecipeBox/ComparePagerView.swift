import SwiftUI
import UIKit

/// Recipe editor + original photo. In portrait they are two swipeable
/// pages; in landscape they sit side by side with a draggable divider.
struct ComparePagerView: View {
    /// The recipe page: one photo, or several stitched together.
    let source: StitchedImage
    /// Regions the person blocked out before OCR (MaskEditorView); the
    /// vision re-read paints them white so that text is skipped there too.
    var excludedRegions: [CGRect] = []
    @Binding var recipe: EditableRecipe
    /// What it takes to save this recipe to My Recipes (see LibraryInfo).
    let libraryInfo: LibraryInfo

    /// Owned here (not in the editor view) so drafts and undo history
    /// survive rotating between the two layouts.
    @StateObject private var model: EditorModel

    @State private var currentPage = 0

    /// Size of the whole window, measured ignoring safe areas so the
    /// keyboard appearing can't make a tall iPad look "landscape".
    @State private var windowSize = UIScreen.main.bounds.size
    /// Share of the width given to the editor in landscape (0.25...0.75).
    @AppStorage("compare.splitFraction") private var splitFraction = 0.5

    @State private var isReadingWithVision = false
    @State private var visionError: String?
    /// The saved recipe from before a vision re-read replaced it.
    @State private var recipeBeforeVision: EditableRecipe?
    @State private var confirmVisionDiscardsEdits = false
    @State private var confirmDiscardOnBack = false
    /// The keyboard is showing. In landscape that leaves very little height,
    /// so the photo steps aside and the editor takes the full width.
    @State private var keyboardUp = false
    /// Whether the recipe is stored in My Recipes. Once it is, every Save
    /// in the editor is written through to the database.
    @State private var inLibrary: Bool
    @State private var libraryMessage: String?
    @State private var confirmLibraryOtherEdits = false

    @Environment(\.dismiss) private var dismiss

    init(
        source: StitchedImage,
        excludedRegions: [CGRect] = [],
        recipe: Binding<EditableRecipe>,
        libraryInfo: LibraryInfo = LibraryInfo()
    ) {
        self.source = source
        self.excludedRegions = excludedRegions
        self.libraryInfo = libraryInfo
        _inLibrary = State(initialValue: libraryInfo.isSaved)
        _recipe = recipe
        _model = StateObject(wrappedValue: EditorModel(saved: recipe.wrappedValue))
    }

    private var originalImage: UIImage { source.composite }

    private var isLandscape: Bool { windowSize.width > windowSize.height }

    var body: some View {
        Group {
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in windowSize = newSize }
            }
            .ignoresSafeArea()
        )
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        // Landscape has little height to spare: the editor's own thin row
        // carries the back button instead.
        .toolbar(isLandscape ? .hidden : .automatic, for: .navigationBar)
        // With unsaved edits, replace the back button (and its swipe-back
        // gesture) with one that asks first.
        .navigationBarBackButtonHidden(model.hasUnsavedEdits)
        .toolbar {
            if model.hasUnsavedEdits {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmDiscardOnBack = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            if recipeBeforeVision != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Undo AI Re-read") { undoAIReread() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                libraryButton
            }
        }
        // Keep the screen that started this flow in step with what's saved,
        // and keep My Recipes in step once the recipe has been added there.
        .onChange(of: model.saved) { _, newSaved in
            recipe = newSaved
            if inLibrary { storeInLibrary() }
        }
        .alert("Save your edits first", isPresented: $confirmLibraryOtherEdits) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Fields and Text views both have unsaved edits. Tap Save in the view you want to keep, then add the recipe to My Recipes.")
        }
        .alert("My Recipes", isPresented: Binding(
            get: { libraryMessage != nil },
            set: { if !$0 { libraryMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryMessage ?? "")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscardOnBack, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Replace unsaved edits?", isPresented: $confirmVisionDiscardsEdits) {
            Button("Re-read and Discard Edits", role: .destructive) { startVisionRead() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The AI re-read replaces the recipe, including edits you haven't saved.")
        }
        .alert("Couldn't re-read the photo", isPresented: Binding(
            get: { visionError != nil },
            set: { if !$0 { visionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(visionError ?? "")
        }
    }

    // MARK: - Layouts

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                RecipeEditView(model: model)
                    .tag(0)

                imagePane(bottomPadding: 44) // clear of the page-indicator dots
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack(spacing: 6) {
                Image(systemName: currentPage == 0 ? "text.alignleft" : "photo")
                Text(currentPage == 0 ? "Recipe (editable)" : "Original Photo")
                    .font(.caption.bold())
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
        }
    }

    private let dividerWidth: CGFloat = 22

    private var landscapeLayout: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let fraction = min(max(splitFraction, 0.25), 0.75)
            let editorWidth = max(total * fraction - dividerWidth / 2, 0)

            HStack(spacing: 0) {
                RecipeEditView(
                    model: model,
                    compact: true,
                    onBack: goBack,
                    onUndoAIReread: recipeBeforeVision == nil ? nil : { undoAIReread() },
                    inLibrary: inLibrary,
                    onLibrary: { addToLibrary() }
                )
                .frame(width: keyboardUp ? total : editorWidth)

                if !keyboardUp {
                    divider(totalWidth: total)

                    imagePane(bottomPadding: 12)
                        .frame(maxWidth: .infinity)
                }
            }
            .coordinateSpace(name: "compareSplit")
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) { keyboardUp = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) { keyboardUp = false }
            }
        }
    }

    /// Draggable bar between the editor and the photo. Dragging is measured
    /// in the container's coordinate space (not the bar's own, which moves
    /// as it is dragged) so it tracks the finger without jitter.
    private func divider(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 5, height: 44)
        }
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("compareSplit"))
                .onChanged { value in
                    guard totalWidth > 0 else { return }
                    splitFraction = min(max(Double(value.location.x / totalWidth), 0.25), 0.75)
                }
        )
        .accessibilityLabel("Resize editor and photo")
    }

    private func imagePane(bottomPadding: CGFloat) -> some View {
        ImageDisplayView(image: originalImage)
            .overlay(alignment: .bottom) { visionButton(bottomPadding: bottomPadding) }
    }

    // MARK: - My Recipes

    private var libraryButton: some View {
        Button {
            addToLibrary()
        } label: {
            Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
        }
        .accessibilityLabel(inLibrary ? "Saved in My Recipes" : "Add to My Recipes")
    }

    /// Bookmark tapped: store the recipe, taking in any edits that are
    /// waiting in the current view first.
    private func addToLibrary() {
        if inLibrary {
            libraryMessage = "This recipe is saved in My Recipes. Changes you Save in the editor are kept there automatically."
            return
        }
        if model.hasUnsavedEdits {
            if model.otherDirty {
                confirmLibraryOtherEdits = true
                return
            }
            Self.dismissKeyboard()
            model.saveCurrent()
        }
        storeInLibrary()
    }

    private func storeInLibrary() {
        do {
            try RecipeLibrary.shared.save(
                id: libraryInfo.id,
                recipe: model.saved,
                sourceRefs: libraryInfo.sourceRefs,
                sourceText: libraryInfo.sourceText,
                excludedRegions: excludedRegions,
                removeOverlap: libraryInfo.removeOverlap
            )
            if !inLibrary {
                inLibrary = true
                libraryMessage = "Added to My Recipes."
            }
        } catch {
            libraryMessage = "Couldn't save to My Recipes. \(error.localizedDescription)"
        }
    }

    private static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Navigation

    private func goBack() {
        if model.hasUnsavedEdits {
            confirmDiscardOnBack = true
        } else {
            dismiss()
        }
    }

    // MARK: - AI Vision

    private func undoAIReread() {
        guard let previous = recipeBeforeVision else { return }
        model.reset(to: previous)
        recipeBeforeVision = nil
        currentPage = 0
    }

    private func visionButton(bottomPadding: CGFloat) -> some View {
        Button {
            if model.hasUnsavedEdits {
                confirmVisionDiscardsEdits = true
            } else {
                startVisionRead()
            }
        } label: {
            if isReadingWithVision {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading…")
                }
            } else {
                Label("Re-read", systemImage: "eye")
            }
        }
        .font(.footnote.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 2)
        .accessibilityLabel("Re-read with AI Vision")
        .disabled(isReadingWithVision)
        .padding(.bottom, bottomPadding)
    }

    private func startVisionRead() {
        guard let parser = RecipeParserFactory.makeImageParser(excludedRegions: excludedRegions) else {
            visionError = "AI Vision needs an AI engine. Pick Claude or ChatGPT in Settings (the On-Device engine can't read photos directly)."
            return
        }
        isReadingWithVision = true
        parser.parseRecipe(from: source) { result in
            DispatchQueue.main.async {
                isReadingWithVision = false
                switch result {
                case .success(let parsed):
                    recipeBeforeVision = model.saved
                    var reread = EditableRecipe(from: parsed)
                    // Pictures stay with the recipe; the new rows are new, so
                    // they go back to belonging to the recipe as a whole.
                    reread.photos = model.saved.photosDetachedFromRows
                    model.reset(to: reread)
                    currentPage = 0 // show the new result next to the photo it came from
                case .failure(let error):
                    visionError = error.localizedDescription
                }
            }
        }
    }
}
