import Foundation
import UIKit

/// Global network manager that routes requests to independent, domain-specific throttlers.
class ThrottledNetworkManager: @unchecked Sendable {
    static let shared = ThrottledNetworkManager()

    private let lock = NSLock()
    private var throttlers: [String: DomainThrottler] = [:]

    private init() {}

    private func isLocalOrNavidromeHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") || lower.contains("192.168.") || lower.contains("10.") || lower.contains("172.") || lower == "localhost" || lower == "127.0.0.1" {
            return true
        }
        if let savedUrl = UserDefaults.standard.string(forKey: "velora_server_url"),
           let serverHost = URL(string: savedUrl)?.host?.lowercased(),
           lower == serverHost {
            return true
        }
        if let onlineUrl = UserDefaults.standard.string(forKey: "velora_online_server_url"),
           let onlineHost = URL(string: onlineUrl)?.host?.lowercased(),
           lower == onlineHost {
            return true
        }
        return false
    }

    private func getThrottler(for host: String) -> DomainThrottler {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = throttlers[host] { return existing }
        
        let isLocal = isLocalOrNavidromeHost(host)
        
        // Custom rate limits based on host
        let interval: TimeInterval
        let maxConcurrency: Int
        if isLocal {
            interval = 0.0 // Zero artificial delay for home / local Navidrome server
            maxConcurrency = 50 // Full line-rate throughput
        } else if host.contains("musicbrainz.org") {
            interval = 1.0 // Strict 1 request per second
            maxConcurrency = 1
        } else if host.contains("lrclib.net") {
            interval = 1.8 // Strict sequential pacing to avoid 429s (1 request per 1.8s)
            maxConcurrency = 1
        } else if host.contains("fanart.tv") {
            interval = 1.0 // 1 request per second to avoid tarpitting during bulk sync
            maxConcurrency = 1
        } else if host.contains("theaudiodb.com") {
            interval = 1.0 // 1 request per second — free tier
            maxConcurrency = 1
        } else {
            interval = 0.5 // Default 2 requests per second
            maxConcurrency = 2
        }
        
        let newThrottler = DomainThrottler(host: host, minInterval: interval, maxConcurrency: maxConcurrency, isLocal: isLocal)
        throttlers[host] = newThrottler
        return newThrottler
    }

    /// Enqueues a URL Request to be processed at a safe rate by its domain's throttler.
    func enqueue(request: URLRequest, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        let host = request.url?.host ?? "default"
        let throttler = getThrottler(for: host)
        
        let op = ThrottledOperation(request: request, throttler: throttler, completion: completion)
        if priority >= URLSessionTask.highPriority {
            op.queuePriority = .high
        } else if priority <= URLSessionTask.lowPriority {
            op.queuePriority = .low
        } else {
            op.queuePriority = .normal
        }
        throttler.addOperation(op)
    }

    /// Convenience for enqueueing a simple URL
    func enqueue(url: URL, priority: Float = URLSessionTask.defaultPriority, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        enqueue(request: URLRequest(url: url), priority: priority, completion: completion)
    }

    /// Async wrapper for enqueueing a URL Request
    func enqueue(request: URLRequest, priority: Float = URLSessionTask.defaultPriority) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            self.enqueue(request: request, priority: priority) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
        }
    }
}

private class DomainThrottler: @unchecked Sendable {
    let host: String
    let minInterval: TimeInterval
    let isLocal: Bool
    private let defaultMaxConcurrency: Int
    
    private let queue = OperationQueue()
    private var lastRequestTime = Date.distantPast
    private let lock = NSLock()
    
    private var isCircuitOpen = false
    private var circuitResumeTime = Date.distantPast
    var consecutiveFailures = 0

    init(host: String, minInterval: TimeInterval, maxConcurrency: Int = 2, isLocal: Bool = false) {
        self.host = host
        self.minInterval = minInterval
        self.isLocal = isLocal
        self.defaultMaxConcurrency = maxConcurrency
        let isCharging = DevicePowerMonitor.isPluggedInOrCharging
        self.queue.maxConcurrentOperationCount = isCharging ? (isLocal ? 64 : 16) : maxConcurrency

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: .devicePowerStateDidChange,
            object: nil
        )
    }

    @objc private func powerStateChanged(_ notification: Notification) {
        let isCharging = (notification.userInfo?["isCharging"] as? Bool) ?? DevicePowerMonitor.isPluggedInOrCharging
        queue.maxConcurrentOperationCount = isCharging ? (isLocal ? 64 : 16) : defaultMaxConcurrency
    }

    func addOperation(_ op: Operation) {
        queue.addOperation(op)
    }

    func waitForSlot() -> Bool {
        if isLocal || DevicePowerMonitor.isPluggedInOrCharging {
            // Charging or Local: ZERO THROTTLING!
            // Requests proceed at maximum line speed without artificial delay.
            if isCircuitOpen {
                lock.lock()
                defer { lock.unlock() }
                let now = Date()
                if now < circuitResumeTime {
                    return false
                }
                isCircuitOpen = false
            }
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if isCircuitOpen {
            if now < circuitResumeTime {
                let wait = circuitResumeTime.timeIntervalSince(now)
                if wait > 0 && wait <= 30.0 {
                    Thread.sleep(forTimeInterval: wait)
                } else if wait > 30.0 {
                    return false
                }
            }
            // Half-open state: allow this request through to test the waters
            isCircuitOpen = false
            AppLogger.shared.log("🟢 Circuit Breaker half-open for \(host). Testing connection.", level: .info)
        }

        let timeSinceLast = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLast < minInterval {
            Thread.sleep(forTimeInterval: minInterval - timeSinceLast)
        }
        lastRequestTime = Date()
        return true
    }

    func recordCompletion() {
        if isLocal { return }
        lock.lock()
        defer { lock.unlock() }
        lastRequestTime = Date()
    }

    func recordFailure(isRateLimit: Bool = false, retryAfter: TimeInterval? = nil) {
        if isLocal { return } // Never trip circuit breaker for your own local home media server

        lock.lock()
        defer { lock.unlock() }
        
        consecutiveFailures += 1
        
        if isRateLimit || consecutiveFailures >= 3 {
            isCircuitOpen = true
            // Short circuit breaker for content APIs; max 30s default for external services
            let isContentAPI = host.contains("lrclib.net") || host.contains("fanart.tv") || host.contains("theaudiodb.com")
            let seconds = retryAfter ?? (isContentAPI ? 15.0 : 30.0)
            let targetResumeTime = Date().addingTimeInterval(seconds)
            if targetResumeTime > circuitResumeTime {
                circuitResumeTime = targetResumeTime
                AppLogger.shared.log("🛑 Circuit Breaker Tripped for \(host)! Failing fast for \(seconds) seconds.", level: .warning)
            }
        }
    }

    func recordSuccess() {
        if isLocal { return }

        lock.lock()
        defer { lock.unlock() }
        if consecutiveFailures > 0 {
            consecutiveFailures = 0
            AppLogger.shared.log("🟢 Circuit Breaker fully reset for \(host).", level: .info)
        }
    }
}

private class ThrottledOperation: Operation, @unchecked Sendable {
    let request: URLRequest
    let throttler: DomainThrottler
    let completion: (Data?, URLResponse?, Error?) -> Void

    private var _executing = false
    private var _finished = false

    override var isAsynchronous: Bool { true }
    
    override var isExecuting: Bool { _executing }
    override var isFinished: Bool { _finished }

    init(request: URLRequest, throttler: DomainThrottler, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        self.request = request
        self.throttler = throttler
        self.completion = completion
        super.init()
    }

    override func start() {
        guard !isCancelled else { finish(); return }

        willChangeValue(forKey: "isExecuting")
        _executing = true
        didChangeValue(forKey: "isExecuting")

        // Block this background thread until we have a safe slot, or fail fast
        let canProceed = throttler.waitForSlot()
        
        guard canProceed else {
            let error = NSError(domain: "CircuitBreaker", code: 503, userInfo: [NSLocalizedDescriptionKey: "Circuit Breaker open for \(throttler.host). Failing fast."])
            self.completion(nil, nil, error)
            finish()
            return
        }

        guard !isCancelled else { finish(); return }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            var isFailure = false
            
            if let error = error {
                let nsError = error as NSError
                // Timeout or host not found
                if nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorCannotFindHost || nsError.code == NSURLErrorCannotConnectToHost {
                    isFailure = true
                    self.throttler.recordFailure()
                }
            } else if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 || http.statusCode == 403 {
                    isFailure = true
                    var delay: TimeInterval? = nil
                    if let retryStr = http.value(forHTTPHeaderField: "Retry-After"), let retryInt = Double(retryStr) {
                        delay = retryInt
                    }
                    self.throttler.recordFailure(isRateLimit: true, retryAfter: delay)
                } else if http.statusCode >= 500 {
                    isFailure = true
                    self.throttler.recordFailure()
                }
            }
            
            if !isFailure {
                self.throttler.recordSuccess()
            }
            
            self.throttler.recordCompletion()
            self.completion(data, response, error)
            self.finish()
        }
        task.resume()
    }

    private func finish() {
        willChangeValue(forKey: "isExecuting")
        willChangeValue(forKey: "isFinished")
        _executing = false
        _finished = true
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
}