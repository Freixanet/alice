import Foundation

/// What went wrong, in words a person can act on.
///
/// A failure shown as a bare "Hermes did not answer." hid three different
/// things: Hermes refusing with a reason of its own, the network dropping
/// under a call, and Alice cancelling it. Each is told apart here, so the
/// chat says which one happened.
enum HermesErrors {
    static let unanswered = "Hermes did not answer."

    static func describe(_ error: Error, fallback: String = unanswered) -> String {
        if let text = (error as? LocalizedError)?.errorDescription,
           !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return text
        }
        if error is CancellationError { return "Stopped before Hermes answered." }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return network(URLError.Code(rawValue: nsError.code), foundation: nsError.localizedDescription)
        }
        return fallback
    }

    /// A network failure in plain words. Foundation's own text is used when it
    /// has one; an error minted without context only says its code, and that
    /// is translated for the cases a phone actually meets.
    static func network(_ code: URLError.Code, foundation: String) -> String {
        if !foundation.contains("NSURLErrorDomain"), !foundation.contains("couldn’t be completed"),
           !foundation.contains("couldn't be completed") {
            return foundation
        }
        switch code {
        case .notConnectedToInternet: return "This phone is offline."
        case .networkConnectionLost: return "The network connection to Hermes was lost."
        case .timedOut: return "Hermes took too long to answer."
        case .cannotConnectToHost, .cannotFindHost: return "Hermes could not be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted: return "The secure connection to Hermes failed."
        default: return PlainWords.transport(code)
        }
    }
}
