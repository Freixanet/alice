import AVFoundation
import Observation

/// Reads a reply out loud.
///
/// Uses the system voice for the text's own language rather than the phone's,
/// so a Spanish answer is not read with an English accent. One utterance at a
/// time: starting a second reply stops the first, which is what tapping the
/// button on another message means.
@MainActor
@Observable
final class ReadAloud {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var speakingID: String?
    private let finish = Finish()

    init() {
        synthesizer.delegate = finish
        finish.done = { [weak self] in self?.speakingID = nil }
    }

    func isSpeaking(_ id: String) -> Bool { speakingID == id }

    /// `language`, a BCP 47 code such as `ja-JP`, when the caller knows it —
    /// a phrase card does; a short phrase is too little to recognise.
    func toggle(_ text: String, id: String, language: String? = nil) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        } catch {
            // Playing at the current session settings is better than silence.
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = language.flatMap(AVSpeechSynthesisVoice.init(language:)) ?? Self.voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        speakingID = id
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingID = nil
    }

    /// Picks a voice from the text itself. `NSLinguisticTagger` recognises the
    /// language without a network round trip.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
        tagger.string = text
        let code = tagger.dominantLanguage ?? Locale.current.language.languageCode?.identifier
        guard let code else { return nil }
        return AVSpeechSynthesisVoice(language: code)
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    /// Clears the playing state when a phrase ends on its own, so its button
    /// goes back to Play.
    private final class Finish: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        @MainActor var done: (() -> Void)?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.done?() }
        }
    }
}
