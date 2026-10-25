import SwiftUI

/// Page background and text colors, persisted with `@AppStorage`. Raw
/// values are stored, so keep existing ones unchanged.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "白天"
    case sepia = "护眼"
    case green = "豆绿"
    case gray = "浅灰"
    case dark = "夜间"

    var id: Self { self }

    /// Backgrounds for day mode; night mode is always `dark`.
    static let dayThemes: [ReaderTheme] = [.light, .sepia, .green, .gray]

    /// Day/night switch. `theme` is what every screen draws with;
    /// `dayTheme` remembers the day background to return to.
    static func setNight(_ night: Bool, theme: inout ReaderTheme, dayTheme: inout ReaderTheme) {
        if theme != .dark { dayTheme = theme }
        theme = night ? .dark : dayTheme
    }

    var name: String {
        switch self {
        case .light: "白色"
        case .sepia: "米黄"
        case .green: "豆绿"
        case .gray: "浅灰"
        case .dark: "夜间"
        }
    }

    var background: Color {
        switch self {
        case .light: Color(red: 0.99, green: 0.99, blue: 0.98)
        case .sepia: Color(red: 0.96, green: 0.92, blue: 0.82)
        case .green: Color(red: 0.80, green: 0.90, blue: 0.80)
        case .gray: Color(red: 0.90, green: 0.90, blue: 0.89)
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }

    /// List rows and cards on top of `background`, in the same hue, so the
    /// bookshelf and settings match the page.
    var secondaryBackground: Color {
        switch self {
        case .light: .white
        case .sepia: Color(red: 0.99, green: 0.96, blue: 0.89)
        case .green: Color(red: 0.88, green: 0.95, blue: 0.88)
        case .gray: Color(red: 0.96, green: 0.96, blue: 0.95)
        case .dark: Color(red: 0.17, green: 0.17, blue: 0.18)
        }
    }

    var text: Color {
        switch self {
        case .light: Color(white: 0.12)
        case .sepia: Color(red: 0.25, green: 0.2, blue: 0.13)
        case .green: Color(red: 0.13, green: 0.2, blue: 0.13)
        case .gray: Color(white: 0.15)
        case .dark: Color(white: 0.78)
        }
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

extension View {
    /// Gives a List or Form the theme's page color, so the bookshelf and
    /// settings follow the reading background. Rows take
    /// `theme.secondaryBackground` with `listRowBackground`.
    func themedListBackground(_ theme: ReaderTheme) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
    }
}

/// Which way pages turn. Both modes turn one page at a time and run on
/// across chapter boundaries. Raw values are stored; keep them unchanged.
enum PageTurnMode: String, CaseIterable, Identifiable {
    case vertical = "上下滚动"
    case horizontal = "左右翻页"

    var id: Self { self }

    var name: String {
        switch self {
        case .vertical: "上下翻页"
        case .horizontal: "左右翻页"
        }
    }
}

/// Typography derived from the font size alone: line spacing, paragraph
/// spacing and margins scale with it, so they aren't separate settings.
struct ReaderMetrics: Equatable {
    static let fontSizes: ClosedRange<Double> = 14...32

    let fontSize: CGFloat

    init(fontSize: Double) {
        self.fontSize = CGFloat(min(max(fontSize, Self.fontSizes.lowerBound), Self.fontSizes.upperBound))
    }

    var lineSpacing: CGFloat { (fontSize * 0.6).rounded() }
    var paragraphSpacing: CGFloat { (fontSize * 0.75).rounded() }
    var titleSize: CGFloat { (fontSize * 1.35).rounded() }
    var margin: CGFloat { min(max(fontSize * 1.05, 18), 30).rounded() }

    /// Side margin for a given page width, widened so the text column holds
    /// a whole number of Chinese characters (each one em wide), which keeps
    /// justified lines from being stretched.
    func margin(forWidth width: CGFloat) -> CGFloat {
        guard width > margin * 2 + fontSize else { return margin }
        let columns = ((width - margin * 2) / fontSize).rounded(.down)
        return ((width - columns * fontSize) / 2).rounded(.down)
    }
}

enum AppStorageKey {
    static let fontSize = "reader.fontSize"
    static let theme = "reader.theme"
    static let dayTheme = "reader.dayTheme"
    static let pageTurnMode = "reader.pageTurnMode"
    static let hideAuthorNotes = "reader.hideAuthorNotes"
    static let speechRate = "speech.rate"
    /// `bookSourceUrl` of the source searched first and ranked first.
    static let defaultSource = "search.defaultSource"
    /// Recent search terms, one per line (`SearchHistory`); kept on the device.
    static let searchHistory = "search.history"
}

/// Font size, background and page turning: the reader's 设置 sheet and the
/// Settings tab both show this.
struct ReaderSettingsView: View {
    @AppStorage(AppStorageKey.fontSize) private var fontSize = 19.0
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.pageTurnMode) private var pageTurnMode = PageTurnMode.vertical

    var body: some View {
        Form {
            Section {
                Stepper("\(Int(fontSize)) pt", value: $fontSize, in: ReaderMetrics.fontSizes)
            } header: {
                Text("字号 Font size")
            } footer: {
                Text("行距和段距按字号自动调整。")
            }
            .listRowBackground(theme.secondaryBackground)
            Section {
                ThemePicker()
            } header: {
                Text("背景 Background")
            } footer: {
                Text("白天模式的背景，书架和设置页也用这个颜色。选择背景会切回白天模式。")
            }
            .listRowBackground(theme.secondaryBackground)
            Section("翻页 Page turning") {
                Picker("翻页", selection: $pageTurnMode) {
                    ForEach(PageTurnMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(theme.secondaryBackground)
        }
        .themedListBackground(theme)
    }
}

/// A row of day-background swatches. Picking one also leaves night mode.
struct ThemePicker: View {
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.dayTheme) private var dayTheme = ReaderTheme.light

    /// The day background in use, or the one night mode will return to.
    private var selection: ReaderTheme { theme == .dark ? dayTheme : theme }

    var body: some View {
        HStack {
            ForEach(ReaderTheme.dayThemes) { option in
                Button {
                    dayTheme = option
                    theme = option
                } label: {
                    Circle()
                        .fill(option.background)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selection == option ? 2.5 : 0).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}
