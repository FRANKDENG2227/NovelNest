import SwiftData
import SwiftUI

@main
struct NovelNestApp: App {
    @State private var speech = SpeechController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(speech)
        }
        .modelContainer(for: NovelNestSchema.models)
    }
}

struct ContentView: View {
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light

    var body: some View {
        TabView {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        // The whole app follows the reading theme: dark with 夜间, light otherwise.
        .preferredColorScheme(theme.colorScheme)
    }
}
