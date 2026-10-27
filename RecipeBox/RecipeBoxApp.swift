import SwiftUI

@main
struct RecipeBoxApp: App {
    init() {
        // Opens the recipe database (creating it on first launch) and
        // removes photo files left behind by imports that were never saved.
        RecipeLibrary.shared.collectGarbage()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(AppTheme.accent)
        }
    }
}
