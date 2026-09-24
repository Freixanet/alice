import SwiftUI
import UIKit

/// The agents' shared browser, live on the phone — Alice's side of what
/// Hermes' desktop app does with its in-app browser: you watch the agent
/// browse, and you take over by simply using the page.
///
/// The browser itself runs on the Mac (the Alice plugin's `browser_live.py`,
/// a Chromium the agents' browser tools drive); this is one live view of it,
/// shared by the card in the chat and the full-screen browser so that opening
/// one from the other is the same picture, already there.
@MainActor
@Observable
final class LiveBrowser {
    private(set) var state: SharedBrowserState?
    private(set) var image: UIImage?
    private(set) var title = ""
    private(set) var url = ""
    /// The tab being shown, as the plugin names it.
    private(set) var target: String?
    /// Page size in CSS pixels, for mapping a finger to the page.
    private(set) var pageSize: CGSize?
    private(set) var failure: String?

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sequence = 0

    func attach(_ store: AppStore) { self.store = store }

    /// Someone is looking: frames flow while at least one view watches.
    func watch() {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        await refresh()
        while !Task.isCancelled {
            guard let store, state?.watchable == true else {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
                continue
            }
            do {
                // Long-polls up to a second and a half for a newer frame.
                // Follow the tab the agent is working in; hold still on this one
                // while the person has control, so the page does not jump away.
                let shot = try await store.sharedBrowserFrame(after: sequence, target: humanInControl ? target : nil)
                if !shot.target.isEmpty, shot.target != target {
                    // Another tab: its frames count from its own start.
                    sequence = 0
                }
                if let data = shot.jpeg, let decoded = UIImage(data: data) {
                    sequence = shot.seq
                    image = decoded
                }
                if !shot.title.isEmpty { title = shot.title }
                if !shot.url.isEmpty { url = shot.url }
                if !shot.target.isEmpty { target = shot.target }
                if let width = shot.width, let height = shot.height, width > 0, height > 0 {
                    pageSize = CGSize(width: width, height: height)
                }
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                failure = PlainWords.describe(error, doing: "show the browser")
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            }
        }
    }

    func refresh() async {
        guard let store else { return }
        if let fresh = try? await store.sharedBrowser() { state = fresh }
    }

    func turnOn() async {
        guard let store else { return }
        do {
            state = try await store.setSharedBrowser(on: true)
            failure = nil
        } catch {
            failure = PlainWords.describe(error, doing: "start the browser")
        }
    }

    var humanInControl: Bool { state?.humanInControl == true }

    /// The person takes the browser: agents' browser tools wait until it is handed back.
    func takeOver() async {
        guard let store, !humanInControl else { return }
        do { state = try await store.setSharedBrowserControl(human: true); failure = nil }
        catch { failure = PlainWords.describe(error, doing: "take over the browser") }
    }

    func handBack() async {
        guard let store, humanInControl else { return }
        do { state = try await store.setSharedBrowserControl(human: false); failure = nil }
        catch { failure = PlainWords.describe(error, doing: "hand the browser back") }
    }

    /// What the person does to the page. Nothing is logged.
    func send(_ action: SharedBrowserAction) {
        guard let store else { return }
        Task {
            do { try await store.sharedBrowserInput(action, target: target) }
            catch { failure = PlainWords.describe(error, doing: "use the browser") }
        }
    }

    /// "developer.apple.com" for the address bar.
    var host: String {
        URL(string: url)?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

/// Whether an agent is using the browser in this reply right now.
enum BrowserActivity {
    static func isBrowserTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("browser") || lower.hasPrefix("page_watch")
    }

    static func used(_ tools: [Message.ToolCall]) -> Bool {
        tools.contains { isBrowserTool($0.name) }
    }

    static func running(_ tools: [Message.ToolCall]) -> Bool {
        tools.contains { isBrowserTool($0.name) && $0.status != .done }
    }

    /// What the agent is doing in the browser, in its own words: Hermes asks
    /// each browser step to open with a one-line comment for the person
    /// ("# Adding the bag to the basket"), which arrives as the step's preview.
    static func caption(_ tools: [Message.ToolCall]) -> String? {
        guard let detail = tools.last(where: { isBrowserTool($0.name) })?.detail else { return nil }
        for line in detail.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                let said = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return said.isEmpty ? nil : String(said.prefix(80))
            }
        }
        return nil
    }
}

// MARK: - The card in the chat

/// The page the agent is on, live, under its steps: what Hermes' desktop shows
/// beside the chat. Tapping it opens the browser to take over.
struct LiveBrowserCard: View {
    /// The agent is still working on this reply.
    let working: Bool
    let browsing: Bool
    /// The step under way, as the agent described it.
    var caption: String?

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Namespace private var zoom
    @State private var open = false

    private var live: LiveBrowser { store.liveBrowser }

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Palette.muted(scheme)
                    if let image = live.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .clipped()
                            .transition(.opacity)
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 190)
                .clipped()

                HStack(spacing: 8) {
                    if working && browsing {
                        LivePulse()
                    } else {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(live.title.isEmpty ? String(localized: "Browser") : live.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(working && browsing
                             ? (caption ?? String(localized: "Browsing now · tap to take over"))
                             : live.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Palette.card(scheme))
            .clipShape(.rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Palette.border(scheme).opacity(0.5), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "live-browser", in: zoom)
        .accessibilityLabel(Text("Browser: \(live.title)"))
        .accessibilityHint("Opens the browser to watch or take over.")
        .onAppear { live.watch() }
        .onDisappear { live.unwatch() }
        .fullScreenCover(isPresented: $open) {
            LiveBrowserScreen(agentWorking: working && browsing, caption: caption)
                .navigationTransition(.zoom(sourceID: "live-browser", in: zoom))
        }
    }
}

/// A small red dot that breathes: live.
struct LivePulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Full screen

/// The browser, full screen: the page live, driven by your own fingers — tap
/// to click, drag to scroll, the keyboard to type — with Safari's address bar
/// and controls. While an agent is on it the bar says so; using the page is
/// taking over, and "Stop" ends the agent's turn if you want it to wait.
struct LiveBrowserScreen: View {
    var agentWorking = false
    var caption: String?

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var editingAddress = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var keyboardFocused: Bool
    /// Starts with an invisible character, so Backspace on a field the
    /// phone thinks is empty still reaches the page.
    @State private var typed = LiveBrowserScreen.sentinel
    private static let sentinel = "\u{200B}"
    @State private var dragStart: CGPoint?

    private var live: LiveBrowser { store.liveBrowser }

    private var agentOnIt: Bool { agentWorking && store.isSending && !live.humanInControl }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if live.state?.watchable == true {
                controlBanner
            }
            page
            bottomBar
        }
        .background(Palette.background(scheme).ignoresSafeArea())
        .onAppear { live.watch() }
        .onDisappear {
            live.unwatch()
            // Leaving the browser hands it back: an agent is never left waiting on a closed screen.
            Task { await live.handBack() }
        }
        .overlay(alignment: .bottom) {
            // A field no one sees, so the page can have the keyboard.
            TextField("", text: $typed)
                .focused($keyboardFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .onChange(of: typed) { old, new in type(from: old, to: new) }
                .onSubmit {
                    live.send(.key("Enter"))
                    keyboardFocused = true
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close")

            HStack(spacing: 6) {
                if editingAddress {
                    TextField("Search or enter website", text: $address)
                        .focused($addressFocused)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(go)
                } else {
                    Button {
                        address = live.url
                        editingAddress = true
                        addressFocused = true
                    } label: {
                        HStack(spacing: 5) {
                            if live.url.hasPrefix("https") {
                                Image(systemName: "lock.fill").font(.caption2)
                            }
                            Text(live.host.isEmpty ? String(localized: "Search or enter website") : live.host)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                        .foregroundStyle(live.host.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Palette.muted(scheme), in: .capsule)

            Button {
                if editingAddress {
                    editingAddress = false
                    addressFocused = false
                } else {
                    live.send(.reload)
                }
            } label: {
                Image(systemName: editingAddress ? "xmark.circle.fill" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(editingAddress ? .secondary : .primary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(editingAddress ? "Cancel" : "Reload")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Who is driving. Taking over makes the agents' browser tools wait — for a
    /// sign-in, a code, a CAPTCHA, a payment — until you hand it back; closing
    /// the browser hands it back too.
    private var controlBanner: some View {
        HStack(spacing: 10) {
            if live.humanInControl {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(store.accent.primary(scheme))
                VStack(alignment: .leading, spacing: 1) {
                    Text("You're in control")
                        .font(.subheadline.weight(.medium))
                    Text("Alice waits until you hand it back")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Hand Back") { Task { await live.handBack() } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser.handBack")
            } else {
                if agentOnIt { LivePulse() } else {
                    Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agentOnIt ? "Alice is browsing" : "Alice can use this browser")
                        .font(.subheadline.weight(.medium))
                    if agentOnIt, let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                Button("Take Over") { Task { await live.takeOver() } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser.takeOver")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.card(scheme))
        .animation(.snappy, value: live.humanInControl)
        .animation(.snappy, value: agentOnIt)
    }

    private var bottomBar: some View {
        HStack {
            Button { live.send(.back) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back")
            Spacer()
            Button { live.send(.forward) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Forward")
            Spacer()
            Button { keyboardFocused.toggle() } label: {
                Image(systemName: keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .accessibilityLabel(keyboardFocused ? "Hide Keyboard" : "Type")
            Spacer()
            Button {
                if let url = URL(string: live.url), url.scheme?.hasPrefix("http") == true { openURL(url) }
            } label: { Image(systemName: "safari") }
            .accessibilityLabel("Open in Safari")
            .disabled(URL(string: live.url)?.scheme?.hasPrefix("http") != true)
        }
        .font(.system(size: 19))
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        if let state = live.state, !state.watchable {
            ContentUnavailableView {
                Label("Browser off", systemImage: "globe")
            } description: {
                Text(state.available
                     ? "Start the browser on your Mac to watch your agents browse and use it yourself."
                     : "Install Chrome on your Mac to use the browser.")
            } actions: {
                if state.available {
                    Button("Start Browser") { Task { await live.turnOn() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxHeight: .infinity)
        } else if let image = live.image {
            GeometryReader { geometry in
                let fitted = fit(image.size, in: geometry.size)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .top) {
                        Color.clear
                            .frame(width: fitted.width, height: fitted.height)
                            .contentShape(.rect)
                            .gesture(gestures(in: fitted))
                    }
                    .overlay {
                        if agentOnIt {
                            // The agent is driving: a quiet frame around the page.
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.red.opacity(0.35), lineWidth: 2)
                                .frame(width: fitted.width, height: fitted.height)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .accessibilityLabel(Text("Web page: \(live.title)"))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let failure = live.failure {
            Text(failure)
                .font(.footnote)
                .foregroundStyle(Palette.danger(scheme))
                .padding(.horizontal)
        }
    }

    /// Tap clicks where the finger lands; a drag scrolls by what it moved.
    private func gestures(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
            }
            .onEnded { value in
                defer { dragStart = nil }
                takeOver()
                let moved = value.translation
                let x = Double(value.startLocation.x / size.width)
                let y = Double(value.startLocation.y / size.height)
                if abs(moved.height) < 8 && abs(moved.width) < 8 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    live.send(.tap(x: x, y: y))
                    // A tap on a field is usually followed by typing.
                    return
                }
                // Finger up is the page down, as with any scroll view.
                let dy = Double(-moved.height / size.height)
                live.send(.scroll(x: x, y: y, dy: dy))
            }
    }

    /// Using the page while an agent is on it is taking over.
    private func takeOver() {
        if agentOnIt { Task { await live.takeOver() } }
    }

    private func fit(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    // MARK: Typing

    /// What was typed since the last change goes to the page as text; what
    /// was deleted, as Backspace.
    private func type(from old: String, to new: String) {
        guard old != new else { return }
        takeOver()
        let before = old.replacingOccurrences(of: Self.sentinel, with: "")
        let after = new.replacingOccurrences(of: Self.sentinel, with: "")
        if !new.hasPrefix(Self.sentinel) && after.isEmpty {
            // The invisible character went: one Backspace, and it comes back.
            live.send(.key("Backspace"))
        } else if after.hasPrefix(before) {
            let added = String(after.dropFirst(before.count))
            if !added.isEmpty { live.send(.text(added)) }
        } else if before.hasPrefix(after) {
            for _ in 0..<(before.count - after.count) { live.send(.key("Backspace")) }
        } else {
            for _ in 0..<before.count { live.send(.key("Backspace")) }
            if !after.isEmpty { live.send(.text(after)) }
        }
        // Keep the hidden field short and primed; the page holds the text.
        if !new.hasPrefix(Self.sentinel) || after.count > 200 {
            typed = Self.sentinel
        }
    }

    private func go() {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        editingAddress = false
        addressFocused = false
        guard !raw.isEmpty else { return }
        takeOver()
        let target: String
        if raw.contains(" ") || !raw.contains(".") {
            let query = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
            target = "https://duckduckgo.com/?q=\(query)"
        } else {
            target = raw.hasPrefix("http") ? raw : "https://\(raw)"
        }
        live.send(.navigate(target))
    }
}
