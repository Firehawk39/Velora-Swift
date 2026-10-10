import Foundation
import UIKit

extension Notification.Name {
    static let devicePowerStateDidChange = Notification.Name("VeloraDevicePowerStateDidChange")
}

private final class AtomicPowerState: @unchecked Sendable {
    static let shared = AtomicPowerState()
    private var _isCharging: Bool = false
    private var _hasInitialized: Bool = false
    private let lock = NSLock()

    var isCharging: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if !_hasInitialized {
                _hasInitialized = true
                Task { @MainActor in
                    _ = DevicePowerMonitor.shared
                }
            }
            return _isCharging
        }
        set {
            lock.lock()
            _isCharging = newValue
            _hasInitialized = true
            lock.unlock()
        }
    }
}

/// Central power and charging monitor for Velora.
/// Detects in real time when the iPhone or iPad is plugged in or charging up,
/// enabling unthrottled maximum line-rate networking, downloads, and sync operations.
@MainActor
final class DevicePowerMonitor: ObservableObject {
    static let shared = DevicePowerMonitor()

    @Published private(set) var isCharging: Bool = false

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        self.isCharging = charging
        AtomicPowerState.shared.isCharging = charging

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
    }

    @objc private func batteryStateChanged() {
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        if self.isCharging != charging {
            self.isCharging = charging
            AtomicPowerState.shared.isCharging = charging
            AppLogger.shared.log("⚡ [Power] Charging state changed: \(charging ? "PLUGGED IN / CHARGING (Zero Throttling Enabled)" : "UNPLUGGED / ON BATTERY (Standard Throttling)")", level: .info)
            NotificationCenter.default.post(name: .devicePowerStateDidChange, object: nil, userInfo: ["isCharging": charging])
        }
    }

    /// Thread-safe synchronous property callable from background threads, operation queues, and actors.
    nonisolated static var isPluggedInOrCharging: Bool {
        AtomicPowerState.shared.isCharging
    }
}
