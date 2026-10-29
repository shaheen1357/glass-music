import Foundation
import Network
import Observation

/// Tells the app whether it's online and whether the current path is cellular (or
/// otherwise metered), so automatic network work can respect the "mobile data"
/// setting instead of silently eating a data plan.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "glass.netmon")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor in
                self?.isOnline = online
                self?.isCellular = cellular
            }
        }
        monitor.start(queue: queue)
    }
}
