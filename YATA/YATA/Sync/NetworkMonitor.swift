import Foundation
import Network

@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isConnected: Bool = true

    var onReconnect: (() async -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.aravindhsampath.yata.network-monitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                if !wasConnected && self.isConnected {
                    await self.onReconnect?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
