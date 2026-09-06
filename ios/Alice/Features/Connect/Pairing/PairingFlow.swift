import Foundation
import Observation

/// One pairing attempt: a scanned or opened `alice://pair` link, exchanged
/// for the configuration and applied through the same AppStore paths the
/// manual form uses — so a paired install is stored, restored on launch and
/// forgettable exactly like a hand-typed one.
///
/// The stages mirror what the person on the other side of the screen is
/// watching for: confirm, "connecting to your Hermes…", connected.
@MainActor
@Observable
final class PairingFlow {
    enum Stage: Equatable {
        /// Waiting for the reader to check the device name and confirm.
        case confirming
        case claiming
        case connecting
        case connected(profile: String?)
        case failed(String)
    }

    /// Declared to the Hermes at claim time. The system's real device name
    /// needs an entitlement Alice does not have, so this is a plain, editable
    /// name — better an honest "iPhone" than a generic lie.
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Self.deviceNameKey) }
    }

    private(set) var stage: Stage

    /// Nil when the link did not parse; the stage then carries the reason.
    let payload: PairingPayload?

    private let client = PairingClient()
    private let defaults: UserDefaults

    static let deviceNameKey = "alice.device.name"

    init(link: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            payload = try PairingPayload.parse(link)
            stage = .confirming
        } catch {
            payload = nil
            stage = .failed((error as? PairingPayload.ParseError)?.errorDescription
                ?? "This pairing code is incomplete or damaged.")
        }
        let saved = defaults.string(forKey: Self.deviceNameKey) ?? ""
        deviceName = saved.isEmpty ? "iPhone" : saved
    }

    func run(store: AppStore) async {
        guard let payload, stage == .confirming || stage.isRetryable else { return }
        stage = .claiming
        let claimed: PairingClient.Claimed
        do {
            claimed = try await client.claim(payload, deviceName: deviceName)
        } catch {
            stage = .failed((error as? PairingClient.Failure)?.errorDescription
                ?? HermesClient.describe(error).localizedDescription)
            return
        }

        stage = .connecting
        await store.connect(urlText: claimed.gatewayURLText, key: claimed.gatewayKey)
        if store.isConnected, let dashboardURL = claimed.dashboardURLText {
            // The dashboard is optional on both ends; a claim without one
            // leaves the gateway alone, exactly like the manual form.
            _ = await store.connectDashboard(
                urlText: dashboardURL,
                username: claimed.dashboardUsername ?? "",
                password: claimed.dashboardPassword ?? ""
            )
        }

        if store.isConnected {
            stage = .connected(profile: claimed.profileName)
        } else {
            // The gateway key was verified against the claim, so a failure
            // here is transport, not typing — say what the store saw.
            stage = .failed(store.connectionError ?? "Hermes did not answer.")
        }
    }
}

extension PairingFlow.Stage {
    /// Only a failure may run again; a used token must not be silently
    /// re-claimed into a loop.
    var isRetryable: Bool {
        if case .failed = self { return true }
        return false
    }
}
