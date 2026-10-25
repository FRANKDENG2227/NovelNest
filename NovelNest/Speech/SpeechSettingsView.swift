import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// The listening sheet opened from the reader's 朗读 button while reading:
/// pause/continue and stop, system volume, screen brightness and speech rate.
struct SpeechSettingsView: View {
    static let rates = Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)

    @Environment(SpeechController.self) private var speech
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.speechRate) private var speechRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage(AppStorageKey.theme) private var theme = ReaderTheme.light
    @State private var brightness = Double(Self.screen?.brightness ?? 0.5)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        if speech.isPaused {
                            playbackButton("继续", systemImage: "play.fill") { speech.resume() }
                        } else {
                            playbackButton("暂停", systemImage: "pause.fill") { speech.pause() }
                        }
                        playbackButton("停止", systemImage: "stop.fill") {
                            speech.stop()
                            dismiss()
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("音量 Volume") {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                        SystemVolumeSlider().frame(height: 34)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                }
                .listRowBackground(theme.secondaryBackground)
                Section("亮度 Brightness") {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.min")
                        Slider(value: $brightness, in: 0...1)
                        Image(systemName: "sun.max")
                    }
                }
                .listRowBackground(theme.secondaryBackground)
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "tortoise")
                        Slider(value: $speechRate, in: Self.rates)
                        Image(systemName: "hare")
                    }
                } header: {
                    HStack {
                        Text("语速 Speed")
                        Spacer()
                        Text(rateMultiplier)
                    }
                } footer: {
                    Text("新的语速从下一句开始。")
                }
                .listRowBackground(theme.secondaryBackground)
            }
            .themedListBackground(theme)
            .navigationTitle("朗读设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: brightness) { _, value in Self.screen?.brightness = CGFloat(value) }
        }
    }

    private func playbackButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(theme.secondaryBackground, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }

    /// The rate relative to the system default, e.g. "1.2×".
    private var rateMultiplier: String {
        let multiplier = speechRate / Double(AVSpeechUtteranceDefaultSpeechRate)
        return multiplier.formatted(.number.precision(.fractionLength(1))) + "×"
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

/// The system volume slider. iOS only lets apps change the volume through
/// `MPVolumeView`, which draws nothing in the Simulator.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView() }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
