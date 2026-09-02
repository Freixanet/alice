import SwiftUI

/// Everything the agent can show that is not the conversation.
///
/// Split by where it comes from: the first section is served by the gateway
/// the app is already talking to, the second only by the dashboard, which is
/// a separate process and an optional connection. A section that is not there
/// is not a gap — it is an install without that half.
/// What the agent has made: documents, images, and the links it handed over.
///
/// The catalogues that used to live here — skills, tools, jobs — moved to the
/// drawer, where they are reached in one tap, and the read-only reports moved
/// into Settings. What is left is the part you browse rather than configure.
struct LibraryView: View {
    var body: some View {
        ArtifactsScreen(title: "Library")
    }
}
