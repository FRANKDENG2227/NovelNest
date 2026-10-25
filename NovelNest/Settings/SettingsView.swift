import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query private var books: [Book]
    @AppStorage(AppStorageKey.speechRate) private var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @AppStorage(AppStorageKey.dayTheme) private var dayTheme = ReaderTheme.light

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读 Reading") {
                    Toggle("夜间模式", isOn: Binding(get: { theme == .dark }, set: { night in
                        ReaderTheme.setNight(night, theme: &theme, dayTheme: &dayTheme)
                    }))
                    NavigationLink("字号、背景与翻页") { ReaderSettingsView().navigationTitle("阅读设置") }
                }
                .listRowBackground(theme.secondaryBackground)
                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $speechRate, in: SpeechSettingsView.rates)
                        Image(systemName: "hare")
                    }
                } header: {
                    Text("朗读语速 Speech rate")
                } footer: {
                    Text("朗读使用系统自带的语音，书的内容不会上传。\nSpeech uses on-device system voices; book text is never uploaded.")
                }
                .listRowBackground(theme.secondaryBackground)
                Section("存储 Storage") {
                    LabeledContent("书籍", value: "\(books.count)")
                    LabeledContent("章节", value: "\(books.reduce(0) { $0 + $1.chapters.count })")
                }
                .listRowBackground(theme.secondaryBackground)
                Section("关于 About") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
                .listRowBackground(theme.secondaryBackground)
            }
            .themedListBackground(theme)
            .navigationTitle("设置")
        }
    }
}
