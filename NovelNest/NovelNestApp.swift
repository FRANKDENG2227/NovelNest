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
    var body: some View {
        TabView {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
