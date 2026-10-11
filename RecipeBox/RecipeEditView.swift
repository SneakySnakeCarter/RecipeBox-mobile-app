import SwiftUI

struct RecipeEditView: View {
    @Binding var recipeText: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $recipeText)
            .font(.system(.body, design: .default))
            .padding(12)
            .focused($isFocused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }
                }
            }
    }
}
