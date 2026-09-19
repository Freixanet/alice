import Foundation

/// What went wrong, said for the person holding the phone.
///
/// Every screen used to fall back to its own line — "Hermes did not answer."
/// — or to `localizedDescription`, which for a transport error reads
/// "The operation couldn’t be completed. (NSURLErrorDomain error -1004.)".
/// Neither says what happened or why. This does, from the errors Alice
/// actually meets, and only quotes a technical detail when it is the only
/// thing that explains the failure.
enum PlainWords {
    /// `error`, as one or two plain sentences. `doing` names the action for
    /// errors that carry no subject of their own: "save the note".
    static func describe(_ error: Error, doing action: String? = nil) -> String {
        if error is CancellationError { return "That was cancelled before it finished." }

        if let failure = error as? DashboardClient.Failure, case let .http(status, detail) = failure {
            return http(status, detail: detail, action: action)
        }
        if let failure = error as? HermesClient.Failure, case let .http(status, detail, _) = failure {
            return http(status, detail: detail, action: action)
        }
        if let url = error as? URLError {
            return transport(url.code)
        }
        if error is DecodingError {
            return "Hermes sent an answer in a shape Alice doesn’t understand. Updating Alice or Hermes usually fixes this."
        }
        if let said = (error as? LocalizedError)?.errorDescription, !said.isEmpty, !looksTechnical(said) {
            return said
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return transport(URLError.Code(rawValue: ns.code))
        }
        if ns.domain == NSPOSIXErrorDomain {
            return posix(ns.code, action: action)
        }
        if ns.domain == NSCocoaErrorDomain {
            return cocoa(ns.code, action: action)
        }
        let plain = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty, !looksTechnical(plain) {
            return plain
        }
        let what = action.map { "Alice couldn’t \($0)." } ?? "Something in Alice failed."
        return "\(what) The technical reason is “\(ns.domain) \(ns.code)”."
    }

    /// An HTTP status from Hermes, said as what Hermes meant by it.
    static func http(_ status: Int, detail: String?, action: String? = nil) -> String {
        let said: String
        switch status {
        case 400: said = "Hermes didn’t accept the request: something in it was not what it expected."
        case 401: said = "Hermes needs you to sign in again. Check the dashboard login in Connect."
        case 403: said = "Hermes refused this: your login isn’t allowed to do it, or the file is private."
        case 404: said = "Hermes doesn’t have that any more. It may have been moved, renamed or deleted."
        case 408, 504: said = "Hermes took too long to answer. It may be busy; try again in a moment."
        case 409: said = "Hermes says something else changed this first. Reload and try again."
        case 413: said = "That is too big for Hermes to accept."
        case 422: said = "Hermes understood the request but couldn’t apply it as written."
        case 429: said = "Hermes is getting too many requests at once. Wait a moment and try again."
        case 500...503: said = "Hermes hit an internal error (\(status)). Its logs on the computer say why."
        default: said = "Hermes answered with an unexpected status (\(status))."
        }
        let clean = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 160, !looksTechnical(clean), !clean.lowercased().hasPrefix("<") else {
            return said
        }
        let sentence = clean.hasSuffix(".") ? clean : clean + "."
        return said + " Hermes says: " + sentence
    }

    /// A connection failure, said as where the break is.
    static func transport(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return "This iPhone has no internet connection right now."
        case .timedOut:
            return "Hermes didn’t answer in time. It may be asleep, busy or on a network this iPhone can’t reach."
        case .cannotFindHost, .dnsLookupFailed:
            return "This iPhone can’t find the address of your Hermes. If it uses a .local or Tailscale name, make sure you are on that network."
        case .cannotConnectToHost, .networkConnectionLost, .resourceUnavailable:
            return "This iPhone can’t reach Hermes. It may be switched off, or you are on a different network."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "The secure connection to Hermes failed: this iPhone doesn’t trust its certificate."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS refused an unencrypted connection to that address."
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return "Hermes asked for a login this iPhone couldn’t provide."
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
            return "Hermes sent an answer Alice couldn’t read."
        case .cancelled:
            return "That was cancelled before it finished."
        case .fileDoesNotExist, .noPermissionsToReadFile:
            return "That file isn’t on this iPhone any more."
        default:
            return "The connection to Hermes failed (network error \(code.rawValue))."
        }
    }

    private static func posix(_ code: Int, action: String?) -> String {
        let what = action.map { "Alice couldn’t \($0)" } ?? "Alice couldn’t finish"
        switch code {
        case 28: return "\(what): this iPhone is out of storage space."
        case 13, 1: return "\(what): iOS didn’t allow access to that file."
        case 2: return "\(what): the file isn’t there any more."
        default: return "\(what) because of a system error (\(code))."
        }
    }

    private static func cocoa(_ code: Int, action: String?) -> String {
        let what = action.map { "Alice couldn’t \($0)" } ?? "Alice couldn’t finish"
        switch code {
        case NSFileWriteOutOfSpaceError: return "\(what): this iPhone is out of storage space."
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "\(what): the file isn’t there any more."
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "\(what): iOS didn’t allow access to that file."
        case NSUserCancelledError: return "That was cancelled before it finished."
        default: return "\(what) because of a file error (\(code))."
        }
    }

    /// Text a developer wrote for a developer: domains, codes, stack noise.
    static func looksTechnical(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("nsurlerrordomain") || lowered.contains("error domain") || lowered.contains("nscocoaerrordomain") {
            return true
        }
        if lowered.contains("the operation couldn’t be completed") || lowered.contains("the operation couldn't be completed") {
            return true
        }
        if lowered.contains("traceback") || lowered.contains("exception") || lowered.contains("stack trace") {
            return true
        }
        if lowered.range(of: #"\berror -?\d{3,}\b"#, options: .regularExpression) != nil { return true }
        // A raw JSON or HTML body is not a sentence.
        return lowered.hasPrefix("{") || lowered.hasPrefix("[") || lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html")
    }
}
