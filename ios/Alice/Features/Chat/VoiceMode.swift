import AVFoundation
import Observation
import Speech
import SwiftUI

/// A spoken conversation with the chat on screen: you talk, the agent answers
/// aloud, and it listens again — hands free, the way Grok's and Meta's voice
/// modes work, on the phone's own recogniser and voices, so it costs nothing
/// beyond the text turns it sends.
///
/// Speech is sent when you stop talking (a short silence), and the reply is
/// read out paragraph by paragraph as it arrives rather than once it ends.
/// While it speaks the microphone is off, so it never hears itself; a tap
/// interrupts it and hands the turn back.
@MainActor
@Observable
final class VoiceConversation {
    enum Phase: Equatable {
        case paused
        case listening
        case thinking
        case speaking
        case unavailable(String)
    }

    private(set) var phase: Phase = .paused
    /// What it has heard of you so far, live.
    private(set) var heard = ""
    /// What it is saying now.
    private(set) var saying = ""
    /// Microphone level, 0…1, for the orb.
    private(set) var level: CGFloat = 0

    /// How long a pause ends what you are saying.
    static let silence: Duration = .milliseconds(1300)
    /// Listening with nothing heard for this long rests the conversation.
    static let idle: Duration = .seconds(30)

    private weak var store: AppStore?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var watcher: Task<Void, Never>?

    private let synthesizer = AVSpeechSynthesizer()
    private let finish = SpeechFinish()
    private var queued = 0
    private var replyDone = false
    /// Characters of the reply already handed to the voice.
    private var spoken = 0
    /// Messages in the chat before this turn: everything after is the reply.
    private var baseline = 0
    private var conversationID: String?

    init() {
        synthesizer.delegate = finish
        finish.done = { [weak self] in self?.utteranceFinished() }
    }

    // MARK: - Lifecycle

    func begin(store: AppStore) {
        self.store = store
        Task { await listen() }
    }

    func end() {
        silenceTimer?.cancel()
        idleTimer?.cancel()
        watcher?.cancel()
        stopListening()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        queued = 0
        phase = .paused
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The orb: while it speaks, stop and listen; while listening, send what
    /// was heard now; at rest, listen again.
    func tap() {
        switch phase {
        case .speaking, .thinking:
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            queued = 0
            watcher?.cancel()
            Task { await listen() }
        case .listening:
            if heard.trimmingCharacters(in: .whitespaces).isEmpty {
                pause()
            } else {
                sendHeard()
            }
        case .paused, .unavailable:
            Task { await listen() }
        }
    }

    private func pause() {
        stopListening()
        phase = .paused
    }

    // MARK: - Listening

    private func listen() async {
        guard store != nil else { return }
        guard await Self.permitted() else {
            phase = .unavailable("Alice needs the microphone and speech recognition. Turn them on in iOS Settings.")
            return
        }
        stopListening()
        heard = ""
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            phase = .unavailable("Speech recognition is not available right now.")
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                phase = .unavailable("The microphone is not available right now.")
                return
            }
            // Realtime audio thread: nothing here may touch this actor directly.
            nonisolated(unsafe) let sink = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                sink.append(buffer)
                let power = Self.power(of: buffer)
                Task { @MainActor in self?.level = power }
            }
            engine.prepare()
            try engine.start()

            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let failed = error != nil && result == nil
                Task { @MainActor in
                    guard let self, self.phase == .listening else { return }
                    if let text, !text.isEmpty {
                        self.heard = text
                        self.armSilence()
                    } else if failed, self.heard.isEmpty {
                        self.pause()
                    }
                }
            }
            phase = .listening
            armIdle()
        } catch {
            phase = .unavailable("Couldn’t start the microphone.")
            stopListening()
        }
    }

    private func stopListening() {
        silenceTimer?.cancel()
        idleTimer?.cancel()
        recognition?.cancel()
        recognition = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        level = 0
    }

    private func armSilence() {
        silenceTimer?.cancel()
        idleTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.silence)
            guard !Task.isCancelled else { return }
            self?.sendHeard()
        }
    }

    private func armIdle() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled, let self, self.phase == .listening, self.heard.isEmpty else { return }
            self.pause()
        }
    }

    // MARK: - A turn

    private func sendHeard() {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        guard let store, !text.isEmpty else {
            phase = .paused
            return
        }
        conversationID = store.activeChat.id
        baseline = store.shownConversation?.messages.count ?? 0
        spoken = 0
        replyDone = false
        saying = ""
        store.sendQuickReply(text)
        phase = .thinking
        watch()
    }

    /// Follows the reply as it streams, handing each finished paragraph to
    /// the voice as soon as it is whole.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var sawActivity = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let store = self.store else { return }
                guard store.activeChat.id == self.conversationID else { return }
                let messages = store.shownConversation?.messages ?? []
                let reply = messages.dropFirst(min(self.baseline, messages.count))
                    .filter { $0.role == .assistant }
                let writing = reply.contains { $0.pending }
                if writing || store.isSending { sawActivity = true }
                let whole = reply.map(\.content).joined(separator: "\n\n")
                let done = sawActivity && !writing && !store.isSending
                let ready = done ? whole : StreamingReply.split(whole).finished
                self.speak(upTo: ready)
                if done {
                    self.replyDone = true
                    if self.queued == 0 { await self.listen() }
                    return
                }
            }
        }
    }

    private func speak(upTo text: String) {
        guard text.count > spoken else { return }
        let fresh = String(text.dropFirst(spoken))
        spoken = text.count
        let sentences = Self.speakable(fresh)
        guard !sentences.isEmpty else { return }
        if phase != .speaking {
            // Output only: the microphone stays off while it talks.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        phase = .speaking
        let voice = Self.voice(for: sentences)
        for paragraph in sentences.components(separatedBy: "\n") where !paragraph.isEmpty {
            let utterance = AVSpeechUtterance(string: paragraph)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
            utterance.postUtteranceDelay = 0.12
            queued += 1
            synthesizer.speak(utterance)
            if saying.isEmpty { saying = paragraph }
        }
    }

    private func utteranceFinished() {
        queued = max(0, queued - 1)
        if queued == 0 {
            saying = ""
            if replyDone { Task { await listen() } } else { phase = .thinking }
        }
    }

    // MARK: - Helpers

    /// Markdown turned into words to say: no links, code, tables, cards or
    /// symbols read out one by one.
    nonisolated static func speakable(_ markdown: String) -> String {
        var text = markdown
        // Code and card blocks are for the eyes.
        text = text.replacing(/```[\s\S]*?```/, with: "")
        text = text.replacing(/```[\s\S]*$/, with: "")
        text = text.replacing(/\[([^\]]+)\]\([^)]+\)/) { String($0.output.1) }
        text = text.replacing(/https?:\/\/\S+/, with: "")
        text = text.replacing(/\[\d+\]/, with: "")
        text = text.replacing(/\[![A-Z]+\]/, with: "")
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") || line.hasPrefix("---") { continue }
            line = line.replacing(/^(#{1,6}|>|[-*+]|\d+\.)\s+/, with: "")
            line = line.replacing(/^- \[[ xX]\]\s*/, with: "")
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "<u>", with: "")
                .replacingOccurrences(of: "</u>", with: "")
                .replacingOccurrences(of: "$", with: "")
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// The best installed voice for the reply's language: premium, then
    /// enhanced, then the default.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let code = ChatLanguage.of(text) == .english ? "en" : "es"
        let region = code == "es" ? "es-ES" : "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let preferred = voices.filter { $0.language == region }
        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced] {
            if let voice = (preferred + voices).first(where: { $0.quality == quality }) { return voice }
        }
        return AVSpeechSynthesisVoice(language: region)
    }

    nonisolated private static func power(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in stride(from: 0, to: count, by: 4) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(max(1, count / 4))).squareRoot()
        // Speech sits around 0.01–0.2; mapped so a normal voice fills the orb.
        return CGFloat(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 40)))
    }

    private static func permitted() async -> Bool {
        guard await speechAuthorization() == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// `requestAuthorization` answers on a queue of its own. A continuation
    /// resumed from a closure that inherited this actor trips Swift 6's
    /// executor check there and kills the app (the crash the first voice
    /// button had): the request stays off the main actor, as `Dictation` does.
    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private final class SpeechFinish: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        @MainActor var done: (() -> Void)?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.done?() }
        }
    }
}

/// The voice conversation, full screen: an orb that listens, thinks and
/// speaks, what it heard, and what it is saying.
struct VoiceModeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voice = VoiceConversation()

    var body: some View {
        ZStack {
            Palette.background(scheme).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Button { voice.tap() } label: { orb }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hint)

                VStack(spacing: 10) {
                    Text(hint)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    if !voice.saying.isEmpty {
                        Text(voice.saying)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .transition(.opacity)
                    } else if !voice.heard.isEmpty {
                        Text(voice.heard)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 32)
                .frame(minHeight: 120, alignment: .top)
                Spacer()

                Button {
                    voice.end()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("End voice")
                .padding(.bottom, 24)
            }
            .animation(.snappy(duration: 0.3), value: voice.phase)
            .animation(.easeOut(duration: 0.2), value: voice.saying)
        }
        .task {
            voice.begin(store: store)
        }
        .onDisappear { voice.end() }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.phase)
    }

    private var accent: Color { store.accent.primary(scheme) }

    private var hint: String {
        // The chat's own language, from the last thing written in it.
        let last = store.shownConversation?.messages.last(where: { !$0.content.isEmpty })?.content ?? "hola"
        let spanish = ChatLanguage.of(last) == .spanish
        switch voice.phase {
        case .listening: return spanish ? "Te escucho" : "Listening"
        case .thinking: return spanish ? "Pensando…" : "Thinking…"
        case .speaking: return spanish ? "Toca para interrumpir" : "Tap to interrupt"
        case .paused: return spanish ? "Toca para hablar" : "Tap to talk"
        case let .unavailable(reason): return reason
        }
    }

    private var orb: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathing = 1 + 0.04 * sin(t * 2.2)
            let scale: CGFloat = switch voice.phase {
            case .listening: 1 + voice.level * 0.22
            case .thinking: breathing
            case .speaking: 1 + 0.06 * abs(sin(t * 5.5))
            case .paused, .unavailable: 0.92
            }
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 250, height: 250)
                    .scaleEffect(voice.phase == .speaking ? 1 + 0.08 * sin(t * 3) : 1)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.95), accent.opacity(0.55)],
                            center: .init(x: 0.35 + 0.05 * sin(t), y: 0.3), startRadius: 8, endRadius: 150
                        )
                    )
                    .frame(width: 170, height: 170)
                    .overlay {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 1)
                    }
                    .shadow(color: accent.opacity(0.35), radius: 30)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.12), value: voice.level)
            }
            .opacity(voice.phase == .paused ? 0.7 : 1)
        }
        .frame(width: 260, height: 260)
    }
}
