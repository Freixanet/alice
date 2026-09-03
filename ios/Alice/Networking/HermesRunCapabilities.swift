import Foundation

extension HermesClient.Manifest {
    /// Hermes 0.21 can advertise a high-level `runs` flag, idempotent runs, or
    /// the three lower-level run endpoints. Treat all shapes as the same core
    /// capability, matching the web client's contract parser.
    var supportsRuns: Bool {
        let names = normalizedAdvertised
        return names.contains("runs")
            || names.contains("runs_idempotency")
            || (names.contains("run_submission")
                && names.contains("run_status")
                && names.contains("run_events_sse"))
    }

    var supportsRunApprovals: Bool {
        let names = normalizedAdvertised
        return names.contains("approvals")
            || (names.contains("approval_events")
                && (names.contains("run_approval")
                    || names.contains("run_approval_response")))
    }

    var supportsRunIdempotency: Bool {
        normalizedAdvertised.contains("runs_idempotency")
    }

    private var normalizedAdvertised: Set<String> {
        Set(advertised.map {
            $0.lowercased().replacingOccurrences(
                of: "[\\s.-]+",
                with: "_",
                options: .regularExpression
            )
        })
    }
}
