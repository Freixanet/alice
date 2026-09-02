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

    func isSpeaking(_ id: String) -> Bool { speakingID == id }

    func toggle(_ text: String, id: String) {
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
        utterance.voice = Self.voice(for: text)
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
}
