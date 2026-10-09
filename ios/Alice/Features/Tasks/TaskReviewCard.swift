import SwiftUI

struct TaskResultBlocks: View {
    let blocks: [ReviewTask.Block]
    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            VStack(alignment: .leading, spacing: 8) {
                if let title = block.title { Text(title).font(.headline) }
                switch block.type {
                case "text": Text(block.text ?? "")
                case "draft":
                    if let to = block.to, !to.isEmpty { Text(to.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary) }
                    if let subject = block.subject { Text(subject).font(.headline) }
                    Text(block.body ?? "").textSelection(.enabled)
                case "checklist":
                    ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                        Label(item.text, systemImage: item.done ? "checkmark.circle" : "circle")
                    }
                case "table":
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow { ForEach(Array((block.columns ?? []).enumerated()), id: \.offset) { _, column in Text(column).bold() } }
                            ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { _, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell) } }
                            }
                        }
                    }
                case "event":
                    if let start = block.startIso { Text(start) }
                    if let location = block.location { Label(location, systemImage: "mappin") }
                case "link_card":
                    if let value = block.url, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil {
                        Link(block.title ?? value, destination: url)
                    }
                default: Text("This result needs a newer version of Alice.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct TaskReviewCard: View {
    let task: ReviewTask
    let busy: Bool
    let onAccept: () -> Void
    let onChange: (String) -> Void
    @State private var editing = false
    @State private var message = ""
    @State private var confirmingAccept = false

    var body: some View {
        Section(task.status == .blocked ? String(localized: "Your answer is needed") : String(localized: "Your decision is needed")) {
            if let question = task.question { Text(question) }
            if let proposal = task.proposal {
                Text(proposal.description).font(.headline)
                DisclosureGroup("Exact action") {
                    Text(proposal.tool).font(.caption).foregroundStyle(.secondary)
                    Text(proposal.args.formatted).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if task.status == .needsReview {
                Text("Accepting approves this version only. Alice must ask again if the action changes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Accept") { confirmingAccept = true }.disabled(busy)
            }
            Button(task.status == .blocked ? String(localized: "Answer") : String(localized: "Request change")) { editing = true }
                .disabled(busy)
            if editing {
                TextField("What should Alice change or know?", text: $message, axis: .vertical).lineLimit(3...8)
                Button("Send to Alice") { onChange(message) }
                    .disabled(busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("Accept this version of “\(task.title)”?", isPresented: $confirmingAccept, titleVisibility: .visible) {
            Button("Accept and continue") { onAccept() }
        } message: {
            Text(task.proposal?.description ?? task.summary)
        }
    }
}
