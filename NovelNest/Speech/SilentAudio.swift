import AVFoundation

/// Plays silence while reading aloud. AVSpeechSynthesizer renders speech in
/// a system process, so without audio of its own the app never counts as
/// playing: the lock screen shows no Now Playing banner and iOS may suspend
/// the app in the background between sentences.
@MainActor
final class SilentAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isSetUp = false

    func play() {
        if !isSetUp {
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
            else { return }
            buffer.frameLength = buffer.frameCapacity // zero-filled
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            isSetUp = true
        }
        guard (try? engine.start()) != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
        engine.pause()
    }
}
