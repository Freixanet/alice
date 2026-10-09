import Foundation

/// The chat API is independent of the gateway's model catalogue. An idle
/// catalogue request must not hold back messages already saved in Hermes.
enum ChatRecovery {
    @MainActor
    static func run(
        gateway: @escaping @MainActor @Sendable () async -> Void,
        chat: @escaping @MainActor @Sendable () async -> Void
    ) async {
        async let catalogue: Void = gateway()
        await chat()
        await catalogue
    }
}
