import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query private var books: [Book]
    @AppStorage(AppStorageKey.speechRate) private var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读 Reading") {
                    NavigationLink("字号、行距与主题") { ReaderSettingsView().navigationTitle("阅读设置") }
                }
                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $speechRate,
                               in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                        Image(systemName: "hare")
                    }
                } header: {
                    Text("朗读语速 Speech rate")
                } footer: {
                    Text("朗读使用系统自带的语音，书的内容不会上传。\nSpeech uses on-device system voices; book text is never uploaded.")
                }
                Section("存储 Storage") {
                    LabeledContent("书籍", value: "\(books.count)")
                    LabeledContent("章节", value: "\(books.reduce(0) { $0 + $1.chapters.count })")
                }
                Section("关于 About") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .navigationTitle("设置")
        }
    }
}
