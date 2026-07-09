import Foundation
import UIKit

class ThrottledNetworkManager: @unchecked Sendable {
    static let shared = ThrottledNetworkManager()

    private let queue = OperationQueue()
    private var lastRequestTime = Date.distantPast
    private let minInterval: TimeInterval = 0.5 // Maximum 2 requests per second globally
    private let lock = NSLock()
    
    private var isCircuitOpen = false
    private var circuitResumeTime = Date.distantPast

    init() {
        queue.maxConcurrentOperationCount = 2 // Strict concurrency cap
    }

    /// Enqueues a URL Request to be processed at a safe rate.
    func enqueue(request: URLRequest, priority: Float = URLSessionTask.defaultPriority, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        let op = ThrottledOperation(request: request, manager: self, completion: completion)
        // Convert Float [0.0...1.0] to standard queue priorities
        if priority >= URLSessionTask.highPriority {
            op.queuePriority = .high
        } else if priority <= URLSessionTask.lowPriority {
            op.queuePriority = .low
        } else {
            op.queuePriority = .normal
        }
        queue.addOperation(op)
    }

    /// Convenience for enqueueing a simple URL
    func enqueue(url: URL, priority: Float = URLSessionTask.defaultPriority, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        enqueue(request: URLRequest(url: url), priority: priority, completion: completion)
    }

    fileprivate func waitForSlot() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if isCircuitOpen {
            if now < circuitResumeTime {
                let delay = circuitResumeTime.timeIntervalSince(now)
                Thread.sleep(forTimeInterval: delay)
            }
            isCircuitOpen = false
            AppLogger.shared.log("✅ Circuit Breaker reset. Resuming network operations.", level: .info)
        }

        let timeSinceLast = Date().timeIntervalSince(lastRequestTime)
        if timeSinceLast < minInterval {
            Thread.sleep(forTimeInterval: minInterval - timeSinceLast)
        }
        lastRequestTime = Date()
    }

    fileprivate func tripCircuitBreaker(seconds: TimeInterval = 30) {
        lock.lock()
        defer { lock.unlock() }
        isCircuitOpen = true
        // If we get multiple 429s simultaneously, only extend the resume time if the new one is further out
        let targetResumeTime = Date().addingTimeInterval(seconds)
        if targetResumeTime > circuitResumeTime {
            circuitResumeTime = targetResumeTime
            AppLogger.shared.log("⚠️ Circuit Breaker Tripped! API Limit Reached. Pausing network operations for \(seconds) seconds.", level: .warning)
        }
    }
}

private class ThrottledOperation: Operation, @unchecked Sendable {
    let request: URLRequest
    let manager: ThrottledNetworkManager
    let completion: (Data?, URLResponse?, Error?) -> Void

    private var _executing = false
    private var _finished = false

    override var isAsynchronous: Bool { true }
    
    override var isExecuting: Bool { _executing }
    override var isFinished: Bool { _finished }

    init(request: URLRequest, manager: ThrottledNetworkManager, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.request = request
        self.manager = manager
        self.completion = completion
        super.init()
    }

    override func start() {
        guard !isCancelled else { finish(); return }

        willChangeValue(forKey: "isExecuting")
        _executing = true
        didChangeValue(forKey: "isExecuting")

        // Block this background thread until we have a safe slot (enforces rate limit)
        manager.waitForSlot()

        guard !isCancelled else { finish(); return }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let http = response as? HTTPURLResponse {
                // If rate limited or forbidden (likely due to abusive traffic patterns)
                if http.statusCode == 429 || http.statusCode == 403 {
                    var delay: TimeInterval = 30
                    if let retryStr = http.value(forHTTPHeaderField: "Retry-After"), let retryInt = Double(retryStr) {
                        delay = retryInt
                    }
                    self.manager.tripCircuitBreaker(seconds: delay)
                }
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
