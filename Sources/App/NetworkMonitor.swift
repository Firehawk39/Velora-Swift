import Foundation
import Network

/// Connection Mode enum mirroring the user's setting
enum ConnectionMode: Int {
    case local = 0
    case online = 1
    case offlineForced = 2
}

/// Lightweight connectivity tracker using NWPathMonitor.
/// Check `NetworkMonitor.shared.isConnected` anywhere in the app to gate
/// network-dependent operations (downloads, API fetches, scrobbling, etc.).
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    private var physicalConnection: Bool = true

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.velora.network-monitor", qos: .utility)

    private init() {
        // Run an initial evaluation immediately
        evaluateConnectionState()
        
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = (path.status == .satisfied)
            Task { @MainActor in
                self?.physicalConnection = connected
                self?.evaluateConnectionState()
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    /// Re-evaluates isConnected based on both physical connection and user's forced offline setting
    func evaluateConnectionState() {
        let mode = UserDefaults.standard.integer(forKey: "velora_connection_mode")
        if mode == ConnectionMode.offlineForced.rawValue {
            self.isConnected = false
        } else {
            self.isConnected = physicalConnection
        }
    }

    deinit {
        monitor.cancel()
    }
}
