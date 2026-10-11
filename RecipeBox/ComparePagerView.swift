import SwiftUI

struct ComparePagerView: View {
    let originalImage: UIImage
    @Binding var recipeText: String
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                RecipeEditView(recipeText: $recipeText)
                    .tag(0)

                ImageDisplayView(image: originalImage)
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
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
    }
}
