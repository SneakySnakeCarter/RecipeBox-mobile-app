import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var showSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedImage: UIImage?
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

                Text("Snap or choose a photo of a recipe and AI will turn it into editable text you can compare side-by-side with the original.")
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
                        Label("Add Recipe Photo", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)
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
            .alert("API Key Needed", isPresented: $showAPIKeyPrompt) {
                Button("Open Settings") { showSettings = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(selectedEngine.displayName) needs an API key before it can read a recipe. Add one in Settings.")
            }
            .confirmationDialog("Add a photo", isPresented: $showSourceDialog, titleVisibility: .visible) {
                Button("Take Photo") { showCamera = true }
                Button("Choose from Library") { showPhotoPicker = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker(image: $selectedImage)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(image: $selectedImage)
            }
            .onChange(of: selectedImage) { newImage in
                guard newImage != nil else { return }
                // Let the person block out any part of the photo (e.g. a
                // different recipe's text on the same page) before OCR
                // ever runs, rather than parsing immediately.
                parseError = nil
                excludedRegions = []
                showMaskEditor = true
            }
            .navigationDestination(isPresented: $showMaskEditor) {
                if let selectedImage {
                    MaskEditorView(image: selectedImage, isParsing: $isParsing) { regions in
                        excludedRegions = regions
                        parse(image: selectedImage, excludedRegions: regions)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToCompare) {
                if let selectedImage {
                    ComparePagerView(
                        originalImage: selectedImage,
                        excludedRegions: excludedRegions,
                        recipe: $recipe
                    )
                }
            }
        }
    }

    private func parse(image: UIImage, excludedRegions: [CGRect]) {
        isParsing = true
        parseError = nil
        let parser = RecipeParserFactory.makeParser()
        parser.parseRecipe(from: image, excludedRegions: excludedRegions) { result in
            DispatchQueue.main.async {
                isParsing = false
                switch result {
                case .success(let parsed):
                    recipe = EditableRecipe(from: parsed)
                    navigateToCompare = true
                case .failure(let error):
                    parseError = "Couldn't read the recipe: \(error.localizedDescription)"
                    // The error banner lives on this root screen, not on
                    // MaskEditorView, so pop back to it to make sure the
                    // person actually sees why it failed.
                    showMaskEditor = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
