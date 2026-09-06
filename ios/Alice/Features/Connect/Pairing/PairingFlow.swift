import Foundation
import Observation

/// One pairing attempt: a scanned or opened `alice://pair` link, exchanged
/// for the configuration and applied through the same AppStore paths the
/// manual form uses — so a paired install is stored, restored on launch and
/// forgettable exactly like a hand-typed one.
///
/// The one-time claim and the long-lived connections are deliberately two
/// stages. Once the claim succeeds its token is burned, so a later gateway or
/// dashboard retry must reuse the claimed configuration rather than claiming
/// the QR again.
@MainActor
@Observable
final class PairingFlow {
    enum Stage: Equatable {
        /// Waiting for the reader to check the device name and confirm.
        case confirming
        case claiming
        case connecting
        case connected(profile: String?, dashboardWarning: String?)
        case failed(message: String, retryable: Bool)
    }

    /// Declared to Hermes at claim time. The system's real device name needs
    /// an entitlement Alice does not have, so this is a plain, editable name.
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Self.deviceNameKey) }
    }

    private(set) var stage: Stage

    /// Nil when the link did not parse; the stage then carries the reason.
    let payload: PairingPayload?

    private let client: PairingClient
    private let defaults: UserDefaults
    private var claimed: PairingClient.Claimed?

    static let deviceNameKey = "alice.device.name"

    init(
        link: String,
        defaults: UserDefaults = .standard,
        client: PairingClient = PairingClient()
    ) {
        self.defaults = defaults
        self.client = client
        do {
            payload = try PairingPayload.parse(link)
            stage = .confirming
        } catch {
            payload = nil
            stage = .failed(
                message: (error as? PairingPayload.ParseError)?.errorDescription
                    ?? "This pairing code is incomplete or damaged.",
                retryable: false
            )
        }
        let saved = defaults.string(forKey: Self.deviceNameKey) ?? ""
        deviceName = saved.isEmpty ? "iPhone" : saved
    }

    func run(store: AppStore) async {
        guard let payload else { return }

        // A previous claim may already have succeeded. Reuse it: asking the
        // helper for it again can only return "used" and turns a recoverable
        // network hiccup into a dead-end QR.
        if let claimed {
            await connect(claimed, store: store)
            return
        }

        guard stage == .confirming || stage.canRetry else { return }
        stage = .claiming

        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let claimName = trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(64))
        if deviceName != claimName { deviceName = claimName }

        do {
            let result = try await client.claim(payload, deviceName: claimName)
            claimed = result
            await connect(result, store: store)
        } catch {
            let failure = error as? PairingClient.Failure
            stage = .failed(
                message: failure?.errorDescription
                    ?? HermesClient.describe(error).localizedDescription,
                retryable: Self.claimCanRetry(failure)
            )
        }
    }

    /// Retries only the optional dashboard half after the gateway is already
    /// connected. The claim stays consumed and the gateway connection stays
    /// untouched.
    func retryDashboard(store: AppStore) async {
        guard let claimed,
              let dashboardURL = claimed.dashboardURLText,
              store.isConnected
        else { return }

        stage = .connecting
        let warning = await store.connectDashboard(
            urlText: dashboardURL,
            username: claimed.dashboardUsername ?? "",
            password: claimed.dashboardPassword ?? ""
        )
        stage = .connected(
            profile: claimed.profileDisplayName ?? claimed.profileName,
            dashboardWarning: warning
        )
    }

    private func connect(_ claimed: PairingClient.Claimed, store: AppStore) async {
        // Re-pairing is allowed while Alice already has a working Hermes. Keep
        // enough information to restore that connection if the newly claimed
        // gateway turns out to be unreachable. A failed replacement therefore
        // cannot force the reader to re-enter the old key just to get back to
        // where they started.
        let previous: (url: String, key: String)? = {
            guard store.isConnected,
                  !store.gatewayURL.isEmpty,
                  let key = KeyStore.read()
            else { return nil }
            return (store.gatewayURL, key)
        }()

        stage = .connecting
        await store.connect(urlText: claimed.gatewayURLText, key: claimed.gatewayKey)
        guard store.isConnected else {
            var message = store.connectionError ?? "Hermes did not answer."

            if let previous {
                await store.connect(
                    urlText: previous.url,
                    key: previous.key,
                    persist: false
                )
                if !store.isConnected {
                    message += " Your previous Hermes connection could not be restored."
                }
            }

            stage = .failed(message: message, retryable: true)
            return
        }

        var dashboardWarning: String?
        if let dashboardURL = claimed.dashboardURLText {
            // The dashboard is optional in the protocol, but when the helper
            // actually supplied one, failure is shown instead of silently
            // pretending every part of the pairing completed.
            dashboardWarning = await store.connectDashboard(
                urlText: dashboardURL,
                username: claimed.dashboardUsername ?? "",
                password: claimed.dashboardPassword ?? ""
            )
        }

        stage = .connected(
            profile: claimed.profileDisplayName ?? claimed.profileName,
            dashboardWarning: dashboardWarning
        )
    }

    private static func claimCanRetry(_ failure: PairingClient.Failure?) -> Bool {
        guard let failure else { return true }
        switch failure {
        case .stale, .badResponse:
            return false
        case .forbidden, .http, .unreachable, .timedOut, .offline:
            return true
        }
    }
}

extension PairingFlow.Stage {
    var canRetry: Bool {
        if case let .failed(_, retryable) = self { return retryable }
        return false
    }
}
