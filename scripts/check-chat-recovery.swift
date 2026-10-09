import Foundation

@MainActor
final class Probe {
    var gatewayFinished = false
    var historyReads = 0
    var gatewayStarted = false
    var gatewayWaiter: CheckedContinuation<Void, Never>?

    func check() async {
        let recovery = Task {
            await ChatRecovery.run(gateway: {
                self.gatewayStarted = true
                await withCheckedContinuation { self.gatewayWaiter = $0 }
                self.gatewayFinished = true
            }, chat: {
                precondition(!self.gatewayFinished)
                self.historyReads += 1
            })
        }
        while !gatewayStarted { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        precondition(historyReads == 1, "History must load before the catalogue completes")
        precondition(!gatewayFinished)
        gatewayWaiter?.resume()
        await recovery.value
        precondition(gatewayFinished && historyReads == 1)
    }
}

@main struct Check {
    static func main() async {
        await Probe().check()
        print("Chat recovery: one history read while gateway is suspended; both complete")
    }
}
