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
            self.logs.append(LogEntry(message: message, level: level))
            if self.logs.count > 1000 {
                self.logs.removeFirst(self.logs.count - 1000)
            }
        }
        print("[\(level)] \(message)")
    }
}
