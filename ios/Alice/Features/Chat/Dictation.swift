import AVFoundation
import Observation
import Speech

/// Speaking a message instead of typing it.
///
/// Transcription runs against the device's recogniser and writes into the same
/// draft the keyboard writes into, so what you say is editable before it is
/// sent — dictation that posts straight to the agent would give you no chance
/// to catch a misheard word.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case listening
        /// The user said no, or the device cannot transcribe in this locale.
        case unavailable(String)
    }

    private(set) var state: State = .idle

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// What the draft held before dictation started, so the transcript extends
    /// the message rather than replacing it.
    private var prefix = ""

    var isListening: Bool { state == .listening }

    func toggle(locale: Locale = .current, onText: @escaping (String) -> Void) {
        if isListening {
            stop()
        } else {
            Task { await start(locale: locale, onText: onText) }
        }
    }

    private func start(locale: Locale, onText: @escaping (String) -> Void) async {
        guard await requestAccess() else {
            state = .unavailable("Alice needs permission to use the microphone.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("Dictation is not available for this language.")
            return
        }
        self.recognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
                buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        onText(self.prefix.isEmpty ? spoken : self.prefix + " " + spoken)
                    }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
            state = .listening
        } catch {
            state = .unavailable("Couldn’t start the microphone.")
            teardown()
        }
    }

    /// Call before `toggle` so the transcript appends to what is already typed.
    func prime(with draft: String) {
        prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        teardown()
        if case .unavailable = state { return }
        state = .idle
    }

    private func teardown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    private func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
