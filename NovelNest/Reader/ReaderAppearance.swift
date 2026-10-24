import SwiftUI

/// Reader typography and theme, persisted with `@AppStorage`.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "白天"
    case sepia = "护眼"
    case dark = "夜间"

    var id: Self { self }

    var background: Color {
        switch self {
        case .light: Color(red: 0.99, green: 0.99, blue: 0.98)
        case .sepia: Color(red: 0.96, green: 0.92, blue: 0.82)
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }

    var text: Color {
        switch self {
        case .light: Color(white: 0.12)
        case .sepia: Color(red: 0.25, green: 0.2, blue: 0.13)
        case .dark: Color(white: 0.78)
        }
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

enum AppStorageKey {
    static let fontSize = "reader.fontSize"
    static let lineSpacing = "reader.lineSpacing"
    static let horizontalMargin = "reader.horizontalMargin"
    static let theme = "reader.theme"
    static let hideAuthorNotes = "reader.hideAuthorNotes"
    static let speechRate = "speech.rate"
}

struct ReaderSettingsView: View {
    @AppStorage(AppStorageKey.fontSize) private var fontSize = 19.0
    @AppStorage(AppStorageKey.lineSpacing) private var lineSpacing = 8.0
    @AppStorage(AppStorageKey.horizontalMargin) private var margin = 20.0
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light

    var body: some View {
        Form {
            Section("字号 Font size") {
                Stepper("\(Int(fontSize)) pt", value: $fontSize, in: 13...34)
            }
            Section("行距 Line spacing") {
                Slider(value: $lineSpacing, in: 2...20)
            }
            Section("页边距 Margins") {
                Slider(value: $margin, in: 8...40)
            }
            Section("主题 Theme") {
                Picker("主题", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
