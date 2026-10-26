import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var showSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    /// Photos picked or taken for one recipe, before they're stitched.
    @State private var importImages: [ImportedImage] = []
    /// The recipe page everything downstream works on: one photo, or several
    /// stitched into one tall image.
    @State private var source: StitchedImage?
    @State private var showStitchReview = false
    /// Photos taken so far in a camera session (each shot reopens the camera).
    @State private var capturedImages: [ImportedImage] = []
    @State private var showCameraNext = false
    @State private var recipe = EditableRecipe()
    @State private var isParsing = false
    @State private var parseError: String?
    @State private var navigateToCompare = false
    @State private var showSettings = false
    @State private var showAPIKeyPrompt = false
    @State private var showMaskEditor = false
    /// Kept after parsing so the photo page's AI Vision button can paint
    /// the same blocked-out areas white before uploading.
    @State private var excludedRegions: [CGRect] = []
    @State private var showPasteSheet = false
    @State private var showLibrary = false
    /// Where the photo(s) the current recipe is read from are kept (camera
    /// files / library references), and the details the library needs to
    /// save it. Set when a recipe finishes parsing.
    @State private var sourceRefs: [StoredImageRef] = []
    @State private var libraryInfo = LibraryInfo()
    /// True while a shared batch is being read from the App Group inbox.
    @State private var isLoadingShared = false

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(ParserSettingsKeys.selectedEngine)
    private var selectedEngineRaw: String = ParserEngine.claude.rawValue

    private var selectedEngine: ParserEngine {
        ParserEngine(rawValue: selectedEngineRaw) ?? .claude
    }

    /// True when the selected engine is an AI provider with no API key saved yet.
    private var needsAPIKeySetup: Bool {
        guard let provider = selectedEngine.aiProvider else { return false }
        let key = KeychainHelper.shared.read(forKey: provider.apiKeyStorageKey) ?? ""
        return key.isEmpty
    }

    /// Nothing is on screen or running, so it is safe to start an import that
    /// arrived from the Share Extension without pulling the rug out from
    /// under whatever the person is doing.
    private var isIdle: Bool {
        !isParsing && !isLoadingShared
            && !showMaskEditor && !showStitchReview && !navigateToCompare
            && !showSourceDialog && !showPhotoPicker && !showCamera && !showCameraNext
            && !showPasteSheet && !showSettings && !showAPIKeyPrompt
            && capturedImages.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "fork.knife.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 90, height: 90)
                    .foregroundStyle(.orange)

                Text("RecipeBox")
                    .font(.largeTitle.bold())

                Text("Snap or choose photos of a recipe — several are stitched into one — and AI will turn it into editable text you can compare side-by-side with the original.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    showSettings = true
                } label: {
                    Label(selectedEngine.displayName, systemImage: "wand.and.stars")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.15), in: Capsule())
                }

                Spacer()

                if isParsing {
                    ProgressView("Reading recipe…")
                } else {
                    Button {
                        if needsAPIKeySetup {
                            showAPIKeyPrompt = true
                        } else {
                            showSourceDialog = true
                        }
                    } label: {
                        Label("Add Recipe Photos", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)

                    Button {
                        if needsAPIKeySetup {
                            showAPIKeyPrompt = true
                        } else {
                            showPasteSheet = true
                        }
                    } label: {
                        Label("Paste Recipe Text", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }

                    Button {
                        showLibrary = true
                    } label: {
                        Label("My Recipes", systemImage: "books.vertical")
                            .font(.subheadline)
                    }
                }

                if let parseError {
                    Text(parseError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showPasteSheet) {
                PasteRecipeView { text in startTextImport(text) }
            }
            // Pick up anything sent from the Share Extension.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { importSharedItems(promptForKey: true) }
            }
            .onChange(of: isIdle) { _, idle in
                if idle { importSharedItems(promptForKey: false) }
            }
            .alert("API Key Needed", isPresented: $showAPIKeyPrompt) {
                Button("Open Settings") { showSettings = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(selectedEngine.displayName) needs an API key before it can read a recipe. Add one in Settings.")
            }
            .confirmationDialog("Add photos", isPresented: $showSourceDialog, titleVisibility: .visible) {
                Button("Take Photo") {
                    capturedImages = []
                    showCamera = true
                }
                Button("Choose from Library (up to \(PhotoImportLimits.maxPhotos))") { showPhotoPicker = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker { picked in
                    showPhotoPicker = false
                    importPicked(picked)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(
                    onCaptured: { image in
                        // Photos taken here are kept in the app's own folder.
                        if let ref = PhotoStore.saveToFolder(image) {
                            capturedImages.append(ImportedImage(image: image, ref: ref))
                        } else {
                            parseError = "That photo couldn't be saved."
                        }
                        showCamera = false
                        askAboutMoreCameraPhotos()
                    },
                    onCancel: {
                        showCamera = false
                        if !capturedImages.isEmpty { askAboutMoreCameraPhotos() }
                    }
                )
            }
            .confirmationDialog(
                "\(capturedImages.count) photo\(capturedImages.count == 1 ? "" : "s") taken",
                isPresented: $showCameraNext,
                titleVisibility: .visible
            ) {
                if capturedImages.count < PhotoImportLimits.maxPhotos {
                    Button("Take Another") { showCamera = true }
                }
                Button("Done") {
                    let photos = capturedImages
                    capturedImages = []
                    beginImport(photos)
                }
                Button("Discard Photos", role: .destructive) { capturedImages = [] }
            }
            .navigationDestination(isPresented: $showStitchReview) {
                StitchReviewView(images: $importImages) { stitched in
                    source = stitched
                    sourceRefs = importImages.map(\.ref)
                    excludedRegions = []
                    showMaskEditor = true
                }
            }
            .navigationDestination(isPresented: $showMaskEditor) {
                if let source {
                    MaskEditorView(source: source, isParsing: $isParsing) { regions in
                        excludedRegions = regions
                        parse(source: source, excludedRegions: regions)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToCompare) {
                if let source {
                    ComparePagerView(
                        source: source,
                        excludedRegions: excludedRegions,
                        recipe: $recipe,
                        libraryInfo: libraryInfo
                    )
                }
            }
            .navigationDestination(isPresented: $showLibrary) {
                LibraryView()
            }
        }
    }

    /// Photos arrive here from the library picker or the camera session. One
    /// photo goes straight to the mask step; several get a review/stitch
    /// step first.
    private func beginImport(_ images: [ImportedImage]) {
        guard !images.isEmpty else { return }
        parseError = nil
        excludedRegions = []
        if images.count == 1 {
            source = .single(images[0].image)
            sourceRefs = [images[0].ref]
            showMaskEditor = true
        } else {
            importImages = images
            showStitchReview = true
        }
    }

    // MARK: - Shared items and pasted text

    /// Imports the oldest batch waiting in the Share Extension's inbox.
    /// Does nothing unless the app is idle, and leaves the batch in place
    /// (not lost) when an API key is still missing.
    private func importSharedItems(promptForKey: Bool) {
        guard isIdle, let batch = SharedInbox.pendingBatches().first else { return }
        if needsAPIKeySetup {
            if promptForKey { showAPIKeyPrompt = true }
            return
        }

        if !batch.imageFiles.isEmpty {
            isLoadingShared = true
            let limit = PhotoImportLimits.maxPhotos
            DispatchQueue.global(qos: .userInitiated).async {
                // Shared images are copied into the app's photo folder.
                let images: [ImportedImage] = SharedInbox.loadImages(from: batch).prefix(limit).compactMap { image in
                    PhotoStore.saveToFolder(image).map { ImportedImage(image: image, ref: $0) }
                }
                DispatchQueue.main.async {
                    isLoadingShared = false
                    SharedInbox.remove(batch)
                    if images.isEmpty {
                        parseError = "The shared images couldn't be opened."
                    } else {
                        beginImport(images)
                    }
                }
            }
        } else if !batch.text.isEmpty {
            SharedInbox.remove(batch)
            startTextImport(batch.text)
        } else {
            SharedInbox.remove(batch)
        }
    }

    /// Text (pasted or shared) skips the photo and OCR steps entirely.
    private func startTextImport(_ text: String) {
        isParsing = true
        parseError = nil
        TextRecipeParser.parse(text) { result in
            DispatchQueue.main.async {
                isParsing = false
                switch result {
                case .success(let parsed):
                    // The "original" page shows the text itself.
                    source = TextCardRenderer.render(text)
                    sourceRefs = []
                    excludedRegions = []
                    recipe = EditableRecipe(from: parsed)
                    libraryInfo = LibraryInfo(sourceRefs: [], sourceText: text, removeOverlap: false)
                    navigateToCompare = true
                case .failure(let error):
                    parseError = "Couldn't read the recipe: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Library picks: keep a reference to each original in the library when
    /// the app may read it (a copy in the app folder otherwise), then carry on.
    private func importPicked(_ picked: [PickedPhoto]) {
        guard !picked.isEmpty else { return }
        var items = [ImportedImage?](repeating: nil, count: picked.count)
        let group = DispatchGroup()
        for (index, photo) in picked.enumerated() {
            group.enter()
            PhotoStore.refForLibraryPick(image: photo.image, assetID: photo.assetID) { ref in
                if let ref { items[index] = ImportedImage(image: photo.image, ref: ref) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ready = items.compactMap { $0 }
            if ready.isEmpty {
                parseError = "The photos couldn't be saved."
            } else {
                beginImport(ready)
            }
        }
    }

    /// The camera cover needs a moment to finish dismissing before another
    /// presentation can start.
    private func askAboutMoreCameraPhotos() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            showCameraNext = true
        }
    }

    private func parse(source: StitchedImage, excludedRegions: [CGRect]) {
        isParsing = true
        parseError = nil
        let parser = RecipeParserFactory.makeParser()
        parser.parseRecipe(from: source, excludedRegions: excludedRegions) { result in
            DispatchQueue.main.async {
                isParsing = false
                switch result {
                case .success(let parsed):
                    recipe = EditableRecipe(from: parsed)
                    libraryInfo = LibraryInfo(
                        sourceRefs: sourceRefs, sourceText: nil, removeOverlap: source.overlapsRemoved > 0
                    )
                    navigateToCompare = true
                case .failure(let error):
                    parseError = "Couldn't read the recipe: \(error.localizedDescription)"
                    // The error banner lives on this root screen, not on
                    // the mask / join screens, so pop back to it to make
                    // sure the person actually sees why it failed.
                    showMaskEditor = false
                    showStitchReview = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
