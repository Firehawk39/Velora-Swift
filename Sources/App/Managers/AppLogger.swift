import Foundation
import SwiftUI

class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let level: LogLevel
        
        enum LogLevel {
            case debug, info, warning, error
            
            var color: Color {
                switch self {
                case .debug: return .gray
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                }
            }
        }
    }
    
    @Published var logs: [LogEntry] = []
    
    private init() {}
    
    func log(_ message: String, level: LogEntry.LogLevel = .debug) {
        DispatchQueue.main.async {
            self.logs.insert(LogEntry(message: message, level: level), at: 0)
            if self.logs.count > 1000 {
                self.logs.removeLast(self.logs.count - 1000)
            }
        }
        print("[\(level)] \(message)")
    }
}
