import Foundation
import Network

/// Connection Mode enum mirroring the user's setting
enum ConnectionMode: Int {
    case local = 0
    case online = 1
    case offlineForced = 2
}

private final class AtomicNetworkState: @unchecked Sendable {
    static let shared = AtomicNetworkState()
    private var _isConnected: Bool = true
    private var _hasInitialized: Bool = false
    private let lock = NSLock()

    var isConnected: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if !_hasInitialized {
                _hasInitialized = true
                let mode = UserDefaults.standard.integer(forKey: "velora_connection_mode")
                _isConnected = (mode != ConnectionMode.offlineForced.rawValue)
                Task { @MainActor in
                    _ = NetworkMonitor.shared
                }
            }
            return _isConnected
        }
    }

    func update(mode: Int, physical: Bool) {
        let effective: Bool
        if mode == ConnectionMode.offlineForced.rawValue {
            effective = false
        } else if mode == ConnectionMode.local.rawValue {
            effective = true
        } else {
            effective = physical
        }
        lock.lock()
        _isConnected = effective
        _hasInitialized = true
        lock.unlock()
    }
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
            let mode = UserDefaults.standard.integer(forKey: "velora_connection_mode")
            AtomicNetworkState.shared.update(mode: mode, physical: connected)
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
        let effective: Bool
        if mode == ConnectionMode.offlineForced.rawValue {
            effective = false
        } else if mode == ConnectionMode.local.rawValue {
            // Local mode: always allow network requests. URLSession will fail naturally if unreachable.
            // NWPathMonitor often reports .unsatisfied on local networks without internet access.
            effective = true
        } else {
            // Online mode
            effective = physicalConnection
        }
        self.isConnected = effective
        AtomicNetworkState.shared.update(mode: mode, physical: physicalConnection)
    }

    /// Thread-safe synchronous property callable from background threads, operation queues, nonisolated functions, and actors.
    nonisolated static var isConnectedSync: Bool {
        AtomicNetworkState.shared.isConnected
    }

    /// Thread-safe synchronous property callable from background threads, operation queues, nonisolated functions, and actors.
    nonisolated static var isNetworkConnected: Bool {
        AtomicNetworkState.shared.isConnected
    }

    /// Nonisolated static alias for synchronous connectivity checks
    nonisolated static var isConnected: Bool {
        AtomicNetworkState.shared.isConnected
    }
}
