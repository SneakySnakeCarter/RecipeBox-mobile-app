import SwiftUI

/// The editor's "Pictures" section: up to 10 pictures per recipe, each
/// attached to an ingredient, a step, or (by default) the recipe as a whole.
/// Photos taken here are copied into the app's photo folder; photos chosen
/// from the library are stored as references to the originals.
struct RecipePhotosSection: View {
    @Binding var recipe: EditableRecipe

    @State private var showCamera = false
    @State private var showLibraryPicker = false
    @State private var preview: PhotoPreview?
    @State private var message: String?

    private struct PhotoPreview: Identifiable {
        let id = UUID()
        let ref: StoredImageRef
    }

    private struct Option: Identifiable {
        let id: UUID
        let label: String
    }

    private var remaining: Int {
        max(0, RecipePhotoLimits.maxPerRecipe - recipe.photos.count)
    }

    var body: some View {
        Section {
            ForEach($recipe.photos) { $photo in
                row($photo)
            }

            if remaining > 0 {
                Menu {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    Button {
                        showLibraryPicker = true
                    } label: {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Add picture", systemImage: "photo.badge.plus")
                }
            } else {
                Text("That's the limit of \(RecipePhotoLimits.maxPerRecipe) pictures. Remove one to add another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pictures (\(recipe.photos.count) of \(RecipePhotoLimits.maxPerRecipe))")
        } footer: {
            Text("Attach a picture to an ingredient or a step, or leave it on the recipe. Photos taken here are kept in the app. Photos chosen from your library are kept as links to the originals, so deleting one from your library removes it here too.")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCaptured: { image in
                    showCamera = false
                    addCaptured(image)
                },
                onCancel: { showCamera = false }
            )
        }
        .sheet(isPresented: $showLibraryPicker) {
            PhotoLibraryPicker(selectionLimit: remaining, singlePhotoMaxPixel: 2400) { picked in
                showLibraryPicker = false
                addPicked(picked)
            }
        }
        .sheet(item: $preview) { item in
            NavigationStack {
                StoredImageView(ref: item.ref, maxPixel: 2400, fill: false)
                    .padding()
                    .navigationTitle("Picture")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { preview = nil }
                        }
                    }
            }
        }
        .alert("Picture", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Rows

    private func row(_ photo: Binding<RecipePhoto>) -> some View {
        HStack(spacing: 12) {
            StoredImageView(ref: photo.wrappedValue.ref)
                .frame(width: 64, height: 64)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { preview = PhotoPreview(ref: photo.wrappedValue.ref) }

            VStack(alignment: .leading, spacing: 2) {
                Picker("Attached to", selection: photo.attachment) {
                    Text("Whole recipe").tag(PhotoAttachment.recipe)
                    ForEach(ingredientOptions) { option in
                        Text(option.label).tag(PhotoAttachment.ingredient(option.id))
                    }
                    ForEach(stepOptions) { option in
                        Text(option.label).tag(PhotoAttachment.step(option.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(photo.wrappedValue.ref.storage == "asset" ? "Link to your photo library" : "Saved in the app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                let id = photo.wrappedValue.id
                recipe.photos.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove picture")
        }
    }

    private var ingredientOptions: [Option] {
        recipe.ingredientGroups.flatMap { $0.lines }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Option(id: $0.id, label: "Ingredient: " + shortened($0.text)) }
    }

    private var stepOptions: [Option] {
        let steps = recipe.instructionGroups.flatMap { $0.lines }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return steps.enumerated().map { index, line in
            Option(id: line.id, label: "Step \(index + 1): " + shortened(line.text))
        }
    }

    private func shortened(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 34 ? String(trimmed.prefix(34)) + "…" : trimmed
    }

    // MARK: - Adding

    private func addCaptured(_ image: UIImage) {
        guard remaining > 0 else { return }
        if let ref = PhotoStore.saveToFolder(image) {
            recipe.photos.append(RecipePhoto(ref: ref))
        } else {
            message = "That photo couldn't be saved."
        }
    }

    private func addPicked(_ picked: [PickedPhoto]) {
        for photo in picked.prefix(remaining) {
            PhotoStore.refForLibraryPick(image: photo.image, assetID: photo.assetID) { ref in
                guard recipe.photos.count < RecipePhotoLimits.maxPerRecipe else { return }
                if let ref {
                    recipe.photos.append(RecipePhoto(ref: ref))
                } else {
                    message = "A photo couldn't be saved."
                }
            }
        }
    }
}
