import Foundation
import UIKit

/// Global network manager that routes requests to independent, domain-specific throttlers.
class ThrottledNetworkManager: @unchecked Sendable {
    static let shared = ThrottledNetworkManager()

    private let lock = NSLock()
    private var throttlers: [String: DomainThrottler] = [:]

    private init() {}

    private func getThrottler(for host: String) -> DomainThrottler {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = throttlers[host] { return existing }
        
        // Custom rate limits based on host
        let interval: TimeInterval
        if host.contains("musicbrainz.org") {
            interval = 1.0 // Strict 1 request per second
        } else if host.contains("lrclib.net") {
            interval = 0.5 // Safe 2 requests per second to avoid timeouts/tarpitting
        } else {
            interval = 0.5 // Default 2 requests per second
        }
        
        let newThrottler = DomainThrottler(host: host, minInterval: interval)
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
    
    private let queue = OperationQueue()
    private var lastRequestTime = Date.distantPast
    private let lock = NSLock()
    
    private var isCircuitOpen = false
    private var circuitResumeTime = Date.distantPast
    var consecutiveFailures = 0

    init(host: String, minInterval: TimeInterval) {
        self.host = host
        self.minInterval = minInterval
        self.queue.maxConcurrentOperationCount = 2 // Strict concurrency cap per domain
    }

    func addOperation(_ op: Operation) {
        queue.addOperation(op)
    }

    func waitForSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if isCircuitOpen {
            if now < circuitResumeTime {
                // Fail fast
                return false
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

    func recordFailure(isRateLimit: Bool = false, retryAfter: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        consecutiveFailures += 1
        
        if isRateLimit || consecutiveFailures >= 3 {
            isCircuitOpen = true
            let seconds = retryAfter ?? (host.contains("lrclib.net") ? 30.0 : 300.0)
            let targetResumeTime = Date().addingTimeInterval(seconds)
            if targetResumeTime > circuitResumeTime {
                circuitResumeTime = targetResumeTime
                AppLogger.shared.log("🛑 Circuit Breaker Tripped for \(host)! Failing fast for \(seconds) seconds.", level: .warning)
            }
        }
    }

    func recordSuccess() {
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