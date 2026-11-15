import Foundation
import Network
import Observation

/// Whether there is a network, and whether it is metered (cellular, Low Data Mode).
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    /// Called when the connection comes back.
    var onReconnect: (() -> Void)?
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in self?.update(online: online, expensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "de.postfalke.network"))
    }

    private func update(online: Bool, expensive: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        isExpensive = expensive
        if cameBack { onReconnect?() }
    }
}
