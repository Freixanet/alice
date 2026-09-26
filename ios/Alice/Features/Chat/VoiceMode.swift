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
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var recognitionGeneration = 0
    private var tapInstalled = false
    private var ownsAudioSession = false
    private let permission: (@MainActor @Sendable () async -> Bool)?

    private let synthesizer = AVSpeechSynthesizer()
    private let finish = SpeechFinish()
    private var queued = 0
    private var replyDone = false
    /// Characters of the reply already handed to the voice.
    private var spoken = 0
    /// Messages in the chat before this turn: everything after is the reply.
    private var baseline = 0
    private var conversationID: String?

    /// The request the microphone feeds, swapped for a fresh one per thing
    /// said while the engine keeps running (the tap runs on the audio thread).
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ new: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = new } }
        func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request?.append(buffer) } }
    }
    private let feed = Feed()
    /// Everything Alice has said aloud this turn, so her own voice picked up by
    /// the microphone is never taken for the person talking over her.
    private var saidAloud: Set<String> = []
    /// Words that must be new (not her own) before talking over her stops her.
    nonisolated static let bargeInWords = 3

    init(permission: (@MainActor @Sendable () async -> Bool)? = nil) {
        self.permission = permission
        synthesizer.delegate = finish
        finish.done = { [weak self] in self?.utteranceFinished() }
    }

    // MARK: - Lifecycle

    func begin(store: AppStore) {
        self.store = store
        conversationID = store.activeChat.id
        startTask?.cancel()
        startTask = Task { await listen() }
    }

    func end() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        store = nil
        silenceTimer?.cancel()
        idleTimer?.cancel()
        watcher?.cancel()
        stopListening()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        queued = 0
        phase = .paused
    }

    /// The orb: while it speaks, stop and listen; while listening, send what
    /// was heard now; at rest, listen again. Talking does the same without it.
    func tap() {
        switch phase {
        case .speaking:
            interrupt(keeping: "")
        case .thinking:
            phase = .listening
            restartRecognition()
        case .listening:
            if heard.trimmingCharacters(in: .whitespaces).isEmpty {
                pause()
            } else {
                sendHeard()
            }
        case .paused, .unavailable:
            startTask?.cancel()
            startTask = Task { await listen() }
        }
    }

    private func pause() {
        generation += 1
        startTask?.cancel()
        stopListening()
        phase = .paused
    }

    // MARK: - Listening

    /// The microphone stays open for the whole conversation — while Alice
    /// thinks and while she speaks — with the phone's call echo cancellation,
    /// so the person can talk over her or add something while she works.
    private func listen() async {
        guard let store, store.activeChat.id == conversationID else { return }
        generation += 1
        let token = generation
        let allowed = if let permission { await permission() } else { await Self.permitted() }
        guard token == generation, !Task.isCancelled,
              self.store === store, store.activeChat.id == conversationID else { return }
        guard allowed else {
            phase = .unavailable("Alice needs the microphone and speech recognition. Turn them on in iOS Settings.")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            phase = .unavailable("Speech recognition is not available right now.")
            return
        }
        self.recognizer = recognizer
        if !engine.isRunning {
            do {
                let session = AVAudioSession.sharedInstance()
                // voiceChat: the phone's echo cancellation, as in a call.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                try session.setActive(true)
                ownsAudioSession = true
                let input = engine.inputNode
                try? input.setVoiceProcessingEnabled(true)
                input.removeTap(onBus: 0)
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    phase = .unavailable("The microphone is not available right now.")
                    stopListening()
                    return
                }
                let feed = self.feed
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                    feed.append(buffer)
                    let power = Self.power(of: buffer)
                    Task { @MainActor in self?.level = power }
                }
                tapInstalled = true
                engine.prepare()
                try engine.start()
            } catch {
                phase = .unavailable("Couldn’t start the microphone.")
                stopListening()
                return
            }
        }
        phase = .listening
        restartRecognition()
    }

    /// A fresh recognition for the next thing said; the engine keeps running.
    private func restartRecognition() {
        recognitionGeneration += 1
        let token = recognitionGeneration
        silenceTimer?.cancel()
        recognition?.cancel()
        request?.endAudio()
        heard = ""
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        feed.set(request)
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil && result == nil
            Task { @MainActor in
                guard let self, self.recognitionGeneration == token else { return }
                self.heard(text, failed: failed)
            }
        }
        if phase == .listening { armIdle() }
    }

    private func heard(_ text: String?, failed: Bool) {
        guard let store, store.activeChat.id == conversationID else { end(); return }
        guard let text, !text.isEmpty else {
            if failed, phase == .listening, heard.isEmpty { pause() } else if failed { restartRecognition() }
            return
        }
        switch phase {
        case .listening:
            heard = text
            armSilence()
        case .speaking:
            // Only words that are not hers count: the rest is her own voice.
            let fresh = Self.words(text).filter { !saidAloud.contains($0) }
            if fresh.count >= Self.bargeInWords { interrupt(keeping: text) }
        case .thinking:
            // Something to add while she works: listen to it whole, then hand it over.
            if Self.words(text).count >= 2 {
                phase = .listening
                heard = text
                armSilence()
            }
        case .paused, .unavailable:
            break
        }
    }

    /// Talked over, or the orb tapped while she speaks: she stops at once and
    /// listens; the rest of her reply stays in the chat, unread.
    private func interrupt(keeping text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        queued = 0
        saying = ""
        watcher?.cancel()
        phase = .listening
        if text.isEmpty {
            restartRecognition()
        } else {
            heard = text
            armSilence()
        }
    }

    private func stopListening() {
        recognitionGeneration += 1
        silenceTimer?.cancel()
        idleTimer?.cancel()
        recognition?.cancel()
        recognition = nil
        request?.endAudio()
        request = nil
        feed.set(nil)
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
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
            guard !Task.isCancelled, let self, self.phase == .listening, self.heard.isEmpty,
                  self.store?.isSending != true else { return }
            self.pause()
        }
    }

    // MARK: - A turn

    private func sendHeard() {
        guard let store, store.activeChat.id == conversationID else { end(); return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            restartRecognition()
            return
        }
        // Still working on the last thing: this reaches the running task,
        // which keeps going with it; the reply being watched stays the same.
        if store.isSending {
            restartRecognition()
            phase = .thinking
            Task { [weak self] in
                if await store.steerWhileWorking(text) == false { self?.saying = "" }
            }
            return
        }
        baseline = store.shownConversation?.messages.count ?? 0
        spoken = 0
        replyDone = false
        saying = ""
        saidAloud = []
        store.sendQuickReply(text)
        phase = .thinking
        restartRecognition()
        watch()
    }

    /// Follows the reply as it streams, handing each finished paragraph to
    /// the voice as soon as it is whole.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var sawActivity = false
            let sentAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let store = self.store else { return }
                guard store.activeChat.id == self.conversationID else { self.end(); return }
                // Nothing went out: say so, instead of thinking for ever.
                if !sawActivity, (store.shownConversation?.messages.count ?? 0) <= self.baseline,
                   Date().timeIntervalSince(sentAt) > 12 {
                    self.phase = .unavailable("No se pudo enviar. Revisa la conexión con Hermes y toca para reintentar.")
                    return
                }
                let messages = store.shownConversation?.messages ?? []
                let reply = messages.dropFirst(min(self.baseline, messages.count))
                    .filter { $0.role == .assistant }
                let writing = reply.contains { $0.pending }
                if writing || store.isSending { sawActivity = true }
                let whole = reply.map(\.content).joined(separator: "\n\n")
                let done = sawActivity && !writing && !store.isSending
                let ready = done ? whole : StreamingReply.split(whole).finished
                // Talking over her or adding something: do not start speaking over the person.
                if self.phase != .listening { self.speak(upTo: ready) }
                if done {
                    self.replyDone = true
                    if self.queued == 0, self.phase != .listening { self.phase = .listening; self.restartRecognition() }
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
        phase = .speaking
        let voice = Self.voice(for: sentences)
        for paragraph in sentences.components(separatedBy: "\n") where !paragraph.isEmpty {
            saidAloud.formUnion(Self.words(paragraph))
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
        if queued == 0, phase == .speaking {
            saying = ""
            phase = replyDone ? .listening : .thinking
            restartRecognition()
        }
    }

    /// Lowercased words without accents or punctuation, for telling her voice from the person's.
    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
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
                    .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
        .onChange(of: store.activeChat.id) { _, _ in
            voice.end()
            dismiss()
        }
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
