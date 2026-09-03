import SwiftUI

struct ChatScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let onOpenDrawer: () -> Void

    @FocusState private var composerFocused: Bool

    /// Matches the disc the navigation bar drew for these two buttons.
    private let discSize: CGFloat = 44

    var body: some View {
        NavigationStack {
            transcript
                // A plain tap anywhere off the composer dismisses the
                // keyboard; `simultaneousGesture` leaves scrolling and text
                // selection working underneath it.
                .simultaneousGesture(
                    TapGesture().onEnded { composerFocused = false }
                )
                // `safeAreaInset` rather than a layer in a `ZStack`. Overlaid,
                // the composer had to be compensated for with a fixed 120pt
                // of empty space under the transcript — a guess that is wrong
                // the moment the composer grows for an attachment, a second
                // line, or the command list, and wrong again when the keyboard
                // pushes it up. The inset reserves whatever height it actually
                // has. Content still scrolls underneath it; it just no longer
                // comes to rest there.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(focused: $composerFocused)
                }
            .background(Palette.background(scheme))
            .contentShape(.rect)
            .navigationBarTitleDisplayMode(.inline)
            // The bar's own buttons cannot be moved down: iOS 26 draws
            // their glass circles from the bar itself, so offsetting a
            // toolbar button slides the glyph out of a disc that stays put.
            // They are laid out here instead, with the same 44pt disc and
            // the same glass the composer's controls use.
            .toolbar(.hidden, for: .navigationBar)
            // `safeAreaInset` rather than an overlay: it both places the
            // controls and reserves their height, which is the half the
            // navigation bar was quietly doing. As an overlay the first
            // message sat underneath the new-chat button.
            .safeAreaInset(edge: .top, spacing: 0) { topControls }
        }
    }

    private var topControls: some View {
        HStack(spacing: 0) {
            Button(action: onOpenDrawer) {
                // Two bars, not three, matched to the `plus` across from it.
                // Both are math symbols, so the pairing is a real one — but
                // not at the same settings: `equal` at 18pt medium matches
                // the plus's 1.88pt stroke on bars 2pt too short, and going
                // up a size to fix the width thickens it past the plus. 20pt
                // regular lands on both. (`line.3.horizontal`, the usual menu
                // glyph, is a different family and drew at 1.25pt, reading
                // thin beside it.)
                Image(systemName: "equal")
                    .font(.system(size: 20, weight: .regular))
                    .imageScale(.large)
                    .frame(width: discSize, height: discSize)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Chats")

            Spacer(minLength: 0)

            // The mark, not the name: the drawer already says "Alice", and a
            // second wordmark on the screen it opens from is one too many.
            AliceMark(size: 30)
                .foregroundStyle(.primary)
                // Its ink sits 0.75pt above the two glyphs either side, the
                // flags being lighter than the body they sit over.
                .offset(y: 0.75)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            Color.clear
                .frame(width: discSize, height: discSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 11)
        // Something for the conversation to disappear into. The edge effect
        // has nothing to work against when the bar behind these two discs is
        // transparent, so a message scrolling past simply collided with them.
        //
        // Taller than the controls and anchored to the top, so the fade runs
        // out below them: sized to the bar alone it ended exactly where the
        // first line of a message begins, which is where they were colliding.
        .background(alignment: .top) {
            LinearGradient(
                colors: [
                    Palette.background(scheme),
                    Palette.background(scheme),
                    Palette.background(scheme).opacity(0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 190)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear.frame(height: 16).id(bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                // On the scroll view itself, where the effect has an edge to
                // work against. On the container outside it, text ran under
                // the top controls with nothing between them.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                // Opens on the newest message, and stays on it when the
                // scroll view is resized — which is what the keyboard does.
                //
                // One mechanism, not two. Pinning the foot and *also*
                // animating a scroll when the composer took focus meant the
                // conversation moved twice for one keystroke: it went under
                // the composer and then climbed back, which is what read as
                // broken.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: conversation.messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        } else {
            EmptyChatView()
        }
    }

    private var bottomAnchor: String { "bottom" }
}

private struct EmptyChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let botName = store.activeConversation?.botName, !botName.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                BotMarkView(mark: store.mark(for: botName), size: 84, animated: true)
                Text(store.botCurrentName(for: botName))
                    .font(.title2.weight(.bold))
                let liveDetail = store.cachedBots.first(where: { $0.name == botName })?.detail ?? ""
                if !liveDetail.isEmpty {
                    Text(liveDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("What are we working on?")
                    .font(.aliceTitle(.title))
                    .multilineTextAlignment(.center)
                Text("You talk to Alice. One thing at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 140)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
