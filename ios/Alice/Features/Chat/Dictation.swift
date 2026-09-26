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
        case starting
        case listening
        /// The user said no, or the device cannot transcribe in this locale.
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var needsSettings = false

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var ownsAudioSession = false
    /// What the draft held before dictation started, so the transcript extends
    /// the message rather than replacing it.
    private var prefix = ""
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private let permission: (@MainActor @Sendable () async -> Bool)?

    init(permission: (@MainActor @Sendable () async -> Bool)? = nil) {
        self.permission = permission
    }

    var isListening: Bool { state == .listening }

    func toggle(
        locale: Locale = .current,
        onText: @escaping @MainActor @Sendable (String) -> Void
    ) {
        if isListening || startTask != nil {
            stop()
        } else {
            generation += 1
            let token = generation
            state = .starting
            startTask = Task { await start(locale: locale, generation: token, onText: onText) }
        }
    }

    private func start(
        locale: Locale,
        generation token: Int,
        onText: @escaping @MainActor @Sendable (String) -> Void
    ) async {
        defer { if token == generation { startTask = nil } }
        let allowed = if let permission { await permission() } else { await requestAccess() }
        guard token == generation, !Task.isCancelled else { return }
        needsSettings = false
        guard allowed else {
            needsSettings = true
            state = .unavailable(String(localized: "Allow Microphone and Speech Recognition in Settings to dictate."))
            return
        }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable(String(localized: "Dictation is not available for this language."))
            return
        }
        self.recognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            ownsAudioSession = true

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            // The hardware's own format. Asking for the output format can hand
            // back a zero sample rate before the session settles, and
            // `installTap` raises on that.
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                state = .unavailable(String(localized: "The microphone is not available right now."))
                teardown()
                return
            }
            // The tap fires on the realtime audio thread, so the closure must
            // not inherit this actor: an isolation check there aborts the
            // process. `append` is safe to call from that thread.
            nonisolated(unsafe) let sink = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) {
                @Sendable buffer, _ in
                sink.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) {
                @Sendable [weak self] result, error in
                let spokenText = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let spokenText {
                        onText(
                            self.prefix.isEmpty
                                ? spokenText : self.prefix + " " + spokenText
                        )
                    }
                    if done { self.stop() }
                }
            }
            state = .listening
        } catch {
            state = .unavailable(String(localized: "Couldn’t start the microphone."))
            teardown()
        }
    }

    /// Call before `toggle` so the transcript appends to what is already typed.
    func prime(with draft: String) {
        prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
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
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func requestAccess() async -> Bool {
        guard await Self.speechAuthorization() == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// `requestAuthorization` answers on whatever queue it likes. Resuming a
    /// continuation from an actor-isolated closure there trips Swift 6's
    /// executor check and takes the process down with SIGILL, so this stays
    /// off the main actor and the caller hops back on its own.
    private nonisolated static func speechAuthorization()
        async -> SFSpeechRecognizerAuthorizationStatus
    {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
