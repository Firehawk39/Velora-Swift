import Foundation
import SwiftUI
import OSLog

// MARK: - Subsystems

public enum LogSubsystem: String, Codable, CaseIterable, Sendable {
    case general = "General"
    case audio = "Audio"
    case fanart = "Fanart"
    case meshGradient = "MeshGradient"
    case sync = "Sync"
    case network = "Network"
    case storage = "Storage"
    case ui = "UI"
    case mcp = "MCP"

    var icon: String {
        switch self {
        case .general: return "📋"
        case .audio: return "🎵"
        case .fanart: return "🖼️"
        case .meshGradient: return "🎨"
        case .sync: return "🔄"
        case .network: return "🌐"
        case .storage: return "💾"
        case .ui: return "📱"
        case .mcp: return "🤖"
        }
    }
}

// MARK: - Diagnostic Event / Log Entry

public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let subsystem: LogSubsystem
    public let level: LogLevel
    public let message: String
    public let correlationId: String?
    public let durationMs: Double?
    public let metadata: [String: String]

    public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case fault = "FAULT"

        private var priority: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            case .fault: return 4
            }
        }

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            return lhs.priority < rhs.priority
        }

        public var color: Color {
            switch self {
            case .debug: return .gray
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            case .fault: return .purple
            }
        }

        public var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            case .fault: return .fault
            }
        }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        subsystem: LogSubsystem = .general,
        level: LogLevel = .debug,
        message: String,
        correlationId: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.level = level
        self.message = message
        self.correlationId = correlationId
        self.durationMs = durationMs
        self.metadata = metadata
    }

    public var formattedString: String {
        var parts: [String] = []
        parts.append(timestamp.ISO8601Format())
        parts.append("[\(level.rawValue)]")
        parts.append("[\(subsystem.rawValue)]")
        parts.append(message)

        if let cid = correlationId, !cid.isEmpty {
            parts.append("(corr: \(cid))")
        }
        if let dur = durationMs {
            parts.append("[\(String(format: "%.1fms", dur))]")
        }
        if !metadata.isEmpty {
            let meta = metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("{\(meta)}")
        }
        return parts.joined(separator: " ")
    }

    public var jsonDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "timestamp": timestamp.ISO8601Format(),
            "subsystem": subsystem.rawValue,
            "level": level.rawValue,
            "message": message,
            "metadata": metadata
        ]
        if let cid = correlationId { dict["correlationId"] = cid }
        if let dur = durationMs { dict["durationMs"] = dur }
        return dict
    }
}

// MARK: - Persistent Rolling Disk Journal

public actor DiagnosticJournal {
    public static let shared = DiagnosticJournal()

    private let maxFileSizeBytes: Int64 = 4 * 1024 * 1024 // 4MB per log file
    private var writeBuffer: [String] = []
    private var flushTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    private var activeLogUrl: URL {
        VeloraStorage.logs.appendingPathComponent("velora_diagnostics.jsonl")
    }

    private var previousLogUrl: URL {
        VeloraStorage.logs.appendingPathComponent("velora_diagnostics.prev.jsonl")
    }

    private init() {
        startPeriodicFlush()
    }

    private func startPeriodicFlush() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                await self?.flush()
            }
        }
    }

    public func append(_ entry: LogEntry) {
        if let data = try? JSONSerialization.data(withJSONObject: entry.jsonDictionary, options: []),
           let jsonStr = String(data: data, encoding: .utf8) {
            writeBuffer.append(jsonStr)
        }

        // Immediately flush high-severity events to guarantee persistence through unexpected terminations
        if entry.level >= .error || writeBuffer.count >= 40 {
            flush()
        }
    }

    public func flush() {
        guard !writeBuffer.isEmpty else { return }
        let payload = writeBuffer.joined(separator: "\n") + "\n"
        writeBuffer.removeAll(keepingCapacity: true)

        let target = activeLogUrl
        rotateIfNeeded(for: target)

        if let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            if let data = payload.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? payload.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private func rotateIfNeeded(for url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size >= maxFileSizeBytes {
            try? fileManager.removeItem(at: previousLogUrl)
            try? fileManager.moveItem(at: url, to: previousLogUrl)
        }
    }

    /// Reads up to limit historical events from disk (includes prior app run if available)
    public func readHistoricalLogs(
        limit: Int = 100,
        subsystem: LogSubsystem? = nil,
        minLevel: LogEntry.LogLevel? = nil,
        correlationId: String? = nil
    ) -> [LogEntry] {
        flush()
        var entries: [LogEntry] = []

        let urls = [previousLogUrl, activeLogUrl]
        let decoder = JSONDecoder()

        for url in urls {
            guard fileManager.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n")
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(LogEntry.self, from: data) else { continue }

                if let sub = subsystem, entry.subsystem != sub { continue }
                if let minL = minLevel, entry.level < minL { continue }
                if let cid = correlationId, entry.correlationId != cid { continue }

                entries.append(entry)
            }
        }

        return Array(entries.suffix(limit))
    }
}

// MARK: - Enterprise Diagnostic Logger

public final class AppLogger: @unchecked Sendable, ObservableObject {
    public static let shared = AppLogger()

    public typealias LogLevel = LogEntry.LogLevel

    @MainActor @Published public private(set) var logs: [LogEntry] = []
    private let maxMemoryEntries = 2000

    private let osLoggers: [LogSubsystem: Logger] = {
        var dict: [LogSubsystem: Logger] = [:]
        for sub in LogSubsystem.allCases {
            dict[sub] = Logger(subsystem: "com.velora.app", category: sub.rawValue)
        }
        return dict
    }()

    private init() {
        VeloraStorage.ensureDirectories()
    }

    // MARK: - Primary Structured Log API

    public func record(
        subsystem: LogSubsystem,
        level: LogEntry.LogLevel = .debug,
        message: String,
        correlationId: String? = nil,
        durationMs: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        let entry = LogEntry(
            subsystem: subsystem,
            level: level,
            message: message,
            correlationId: correlationId,
            durationMs: durationMs,
            metadata: metadata
        )

        // 1. Apple OSLog / Console Integration
        if let osLogger = osLoggers[subsystem] {
            osLogger.log(level: entry.level.osLogType, "\(entry.formattedString, privacy: .public)")
        } else {
            os_log("%{public}@", entry.formattedString)
        }

        // 2. Persistent Disk Journal
        Task {
            await DiagnosticJournal.shared.append(entry)
        }

        // 3. Fast MainActor Ring Buffer for UI and MCP streams
        Task { @MainActor in
            self.logs.append(entry)
            if self.logs.count > self.maxMemoryEntries {
                self.logs.removeFirst(self.logs.count - self.maxMemoryEntries)
            }
        }
    }

    // MARK: - Backward Compatible Callers

    public func log(_ message: String, level: LogEntry.LogLevel = .debug) {
        let inferredSubsystem = inferSubsystem(from: message)
        let cleanedMessage = stripPrefixes(from: message)
        record(subsystem: inferredSubsystem, level: level, message: cleanedMessage)
    }

    // MARK: - Specialized Subsystem Helpers

    public func audio(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .audio, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func fanart(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .fanart, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func mesh(_ message: String, level: LogEntry.LogLevel = .debug, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .meshGradient, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func sync(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .sync, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func network(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, durationMs: Double? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .network, level: level, message: message, correlationId: correlationId, durationMs: durationMs, metadata: metadata)
    }

    public func storage(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .storage, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func ui(_ message: String, level: LogEntry.LogLevel = .debug, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .ui, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    public func mcp(_ message: String, level: LogEntry.LogLevel = .info, correlationId: String? = nil, metadata: [String: String] = [:]) {
        record(subsystem: .mcp, level: level, message: message, correlationId: correlationId, metadata: metadata)
    }

    // MARK: - Execution Measurement

    public func measure<T>(
        subsystem: LogSubsystem,
        operation: String,
        correlationId: String? = nil,
        metadata: [String: String] = [:],
        block: () throws -> T
    ) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            record(subsystem: subsystem, level: .debug, message: "\(operation) finished", correlationId: correlationId, durationMs: duration, metadata: metadata)
        }
        return try block()
    }

    // MARK: - Query & Diagnostic Inspection

    @MainActor
    public func getRecentLogs(
        limit: Int = 100,
        subsystem: LogSubsystem? = nil,
        minLevel: LogEntry.LogLevel? = nil,
        correlationId: String? = nil
    ) -> [LogEntry] {
        var filtered = logs
        if let sub = subsystem {
            filtered = filtered.filter { $0.subsystem == sub }
        }
        if let minL = minLevel {
            filtered = filtered.filter { $0.level >= minL }
        }
        if let cid = correlationId, !cid.isEmpty {
            filtered = filtered.filter { $0.correlationId == cid }
        }
        return Array(filtered.suffix(limit))
    }

    // MARK: - Subsystem Auto-Detection

    private func inferSubsystem(from msg: String) -> LogSubsystem {
        let lower = msg.lowercased()
        if lower.contains("[fanart]") || lower.contains("[theaudiodb]") || lower.contains("[backdrop]") { return .fanart }
        if lower.contains("[mesh") || lower.contains("palette") || lower.contains("meshgradient") { return .meshGradient }
        if lower.contains("[mcp") { return .mcp }
        if lower.contains("[storage]") || lower.contains("migration") || lower.contains("directory") { return .storage }
        if lower.contains("sync") || lower.contains("[lyricssync]") || lower.contains("[repairsync]") { return .sync }
        if lower.contains("network") || lower.contains("circuit breaker") || lower.contains("http") { return .network }
        if lower.contains("audio") || lower.contains("avplayer") || lower.contains("download") || lower.contains("scrobble") { return .audio }
        if lower.contains("view") || lower.contains("canvas") || lower.contains("portrait") || lower.contains("landscape") { return .ui }
        return .general
    }

    private func stripPrefixes(from msg: String) -> String {
        return msg.replacingOccurrences(of: #"^\[[A-Za-z0-9_\s]+\]\s*"#, with: "", options: .regularExpression)
    }
}
