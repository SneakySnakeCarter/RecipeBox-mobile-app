import SwiftUI

/// Type or paste recipe text (for example a caption copied from somewhere
/// that allows copying) and have it read without a photo.
struct PasteRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Called with the text when the person taps "Read Recipe".
    let onSubmit: (String) -> Void

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .focused($focused)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    if text.isEmpty {
                        Text("Paste the recipe text here — title, ingredients and steps.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            text = pasted
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        let submitted = text
                        dismiss()
                        onSubmit(submitted)
                    } label: {
                        Label("Read Recipe", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .padding()
            .navigationTitle("Paste Recipe Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hide Keyboard") { focused = false }
                }
            }
            .onAppear { focused = true }
        }
    }
}
