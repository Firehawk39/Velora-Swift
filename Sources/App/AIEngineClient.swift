import Foundation

/// A dedicated, ultra-lean network client for communicating with the Python AI Engine.
/// This client assumes the AI Engine runs on the same IP as the Navidrome server, but on port 8000.
@MainActor
final class AIEngineClient {
    static let shared = AIEngineClient()
    
    private let urlSession: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        // We set short timeouts because telemetry should fail fast and silently
        // if the AI server is down, rather than hanging resources.
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 10.0
        self.urlSession = URLSession(configuration: config)
    }
    
    /// Resolves the URL for the AI Engine backend dynamically based on the current Navidrome server URL.
    private var engineBaseUrl: URL? {
        guard let serverStr = UserDefaults.standard.string(forKey: "velora_server_url"),
              var components = URLComponents(string: serverStr) else {
            return URL(string: "http://localhost:8000/api/v1")
        }
        
        // Swap out the Navidrome port (e.g. 4533) for the AI Engine port (8000)
        components.port = 8000
        components.path = "/api/v1"
        return components.url
    }
    
    /// Logs a telemetry event (play, pause, skip) to the AI Engine.
    /// This is a "fire-and-forget" method that will not block the caller or throw errors.
    func logEvent(type: String, trackId: String, context: String = "") {
        guard let baseUrl = engineBaseUrl else { return }
        let endpoint = baseUrl.appendingPathComponent("telemetry/event")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "event_type": type,
            "track_id": trackId,
            "context": context
        ]
        
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = bodyData
        
        // Fire and forget using a detached task
        Task.detached(priority: .background) {
            do {
                let (_, response) = try await self.urlSession.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    AppLogger.shared.log("[AIEngine] Telemetry failed with status: \(httpResponse.statusCode)")
                }
            } catch {
                AppLogger.shared.log("[AIEngine] Telemetry dropped: \(error.localizedDescription)")
            }
        }
    }
}
