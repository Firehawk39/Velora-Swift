import Foundation
import Network
import UIKit

// MARK: - Velora AI Powerhouse MCP Server
/// Native Model Context Protocol (MCP) Server and local AI Engine hub for Velora.
/// Conforms to the MCP JSON-RPC 2.0 specification (2024-11-05).
/// Enables external AI agents (Antigravity, Claude, Cursor) and internal AI engines
/// to query state, control playback, diagnose issues, and execute natural language music intents.
@MainActor
final class VeloraMCPServer: ObservableObject {
    static let shared = VeloraMCPServer()

    @Published var isRunning: Bool = false
    @Published var serverPort: UInt16 = 8765
    @Published var connectedClientsCount: Int = 0
    @Published var lastRequestTime: Date? = nil
    @Published var lastActionSummary: String = "Server initialized"

    private var listener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "com.velora.mcp.server", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    func start(port: UInt16 = 8765) {
        guard !isRunning else { return }
        self.serverPort = port

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10

            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                AppLogger.shared.log("[MCP] Invalid port \(port)", level: .error)
                return
            }

            let newListener = try NWListener(using: params, on: endpointPort)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        AppLogger.shared.log("[MCP Powerhouse] 🚀 Listening on port \(port)", level: .info)
                    case .failed(let error):
                        self.isRunning = false
                        AppLogger.shared.log("[MCP Powerhouse] ❌ Failed to start: \(error.localizedDescription)", level: .error)
                    case .cancelled:
                        self.isRunning = false
                        AppLogger.shared.log("[MCP Powerhouse] Stopped.", level: .info)
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.handleNewConnection(connection)
            }

            newListener.start(queue: queue)
        } catch {
            AppLogger.shared.log("[MCP Powerhouse] Initialization error: \(error.localizedDescription)", level: .error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        connectedClientsCount = 0
        AppLogger.shared.log("[MCP Powerhouse] Stopped manually.", level: .info)
    }

    // MARK: - Connection & HTTP Request Handling

    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNextChunk(on: connection, buffer: Data())
    }

    private nonisolated func receiveNextChunk(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                connection.cancel()
                return
            }

            var updatedBuffer = buffer
            if let data = content {
                updatedBuffer.append(data)
            }

            // Check if full HTTP header has arrived (\r\n\r\n)
            if let headerEndRange = updatedBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = updatedBuffer.subdata(in: 0..<headerEndRange.lowerBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }

                let lines = headerString.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else {
                    connection.cancel()
                    return
                }

                let parts = requestLine.components(separatedBy: " ")
                guard parts.count >= 2 else {
                    connection.cancel()
                    return
                }

                let method = parts[0]
                let path = parts[1]

                // Content-Length header check
                var contentLength = 0
                for line in lines.dropFirst() {
                    let headerParts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if headerParts.count == 2 && headerParts[0].lowercased() == "content-length" {
                        contentLength = Int(headerParts[1]) ?? 0
                    }
                }

                let bodyStart = headerEndRange.upperBound
                let totalExpected = bodyStart + contentLength

                if updatedBuffer.count >= totalExpected {
                    let bodyData = updatedBuffer.subdata(in: bodyStart..<totalExpected)
                    Task { @MainActor in
                        self.processHTTPRequest(method: method, path: path, body: bodyData, connection: connection)
                    }
                } else {
                    // Need more body data
                    self.receiveNextChunk(on: connection, buffer: updatedBuffer)
                }
            } else if !isComplete {
                self.receiveNextChunk(on: connection, buffer: updatedBuffer)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP Router

    @MainActor
    private func processHTTPRequest(method: String, path: String, body: Data, connection: NWConnection) {
        self.lastRequestTime = Date()

        // Handle CORS Preflight
        if method == "OPTIONS" {
            sendHTTPResponse(status: 200, statusText: "OK", headers: corsHeaders(), body: Data(), connection: connection)
            return
        }

        // Quick status check: GET / or GET /status
        if method == "GET" && (path == "/" || path == "/status") {
            let status = buildQuickStatus()
            if let data = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted) {
                var headers = corsHeaders()
                headers["Content-Type"] = "application/json"
                sendHTTPResponse(status: 200, statusText: "OK", headers: headers, body: data, connection: connection)
            }
            return
        }

        // Live Log Stream: GET /logs
        if method == "GET" && path == "/logs" {
            let entries = AppLogger.shared.logs.suffix(100).map { "\($0.timestamp.ISO8601Format()) [\($0.level)] \($0.message)" }.joined(separator: "\n")
            var headers = corsHeaders()
            headers["Content-Type"] = "text/plain; charset=utf-8"
            sendHTTPResponse(status: 200, statusText: "OK", headers: headers, body: Data(entries.utf8), connection: connection)
            return
        }

        // Direct AI Engine Intent: POST /api/intent
        if method == "POST" && path == "/api/intent" {
            Task {
                let result = await self.executeAIEngineIntent(body: body)
                var headers = self.corsHeaders()
                headers["Content-Type"] = "application/json"
                let data = (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data("{}".utf8)
                self.sendHTTPResponse(status: 200, statusText: "OK", headers: headers, body: data, connection: connection)
            }
            return
        }

        // Standard MCP Endpoint: POST /mcp or POST /
        if method == "POST" && (path == "/mcp" || path == "/") {
            Task {
                let responseDict = await self.handleMCPJSONRPC(body: body)
                var headers = self.corsHeaders()
                headers["Content-Type"] = "application/json"
                let data = (try? JSONSerialization.data(withJSONObject: responseDict, options: .prettyPrinted)) ?? Data("{}".utf8)
                self.sendHTTPResponse(status: 200, statusText: "OK", headers: headers, body: data, connection: connection)
            }
            return
        }

        // Not Found
        sendHTTPResponse(status: 404, statusText: "Not Found", headers: corsHeaders(), body: Data("Endpoint not found".utf8), connection: connection)
    }

    private nonisolated func sendHTTPResponse(status: Int, statusText: String, headers: [String: String], body: Data, connection: NWConnection) {
        var headerString = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, val) in headers {
            headerString += "\(key): \(val)\r\n"
        }
        headerString += "Content-Length: \(body.count)\r\n\r\n"

        var fullData = Data(headerString.utf8)
        fullData.append(body)

        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated func corsHeaders() -> [String: String] {
        return [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Requested-With",
            "Connection": "close"
        ]
    }

    // MARK: - MCP JSON-RPC 2.0 Dispatcher

    @MainActor
    private func handleMCPJSONRPC(body: Data) async -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            return [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error: Expected JSON-RPC 2.0 object"]
            ]
        }

        let requestId = json["id"] ?? NSNull()
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": ["listChanged": false],
                        "resources": ["subscribe": false, "listChanged": false],
                        "prompts": ["listChanged": false]
                    ],
                    "serverInfo": [
                        "name": "Velora AI Powerhouse MCP Server",
                        "version": "2.0.0"
                    ]
                ]
            ]

        case "ping":
            return ["jsonrpc": "2.0", "id": requestId, "result": [:]]

        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "result": ["tools": getToolDefinitions()]
            ]

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return [
                    "jsonrpc": "2.0",
                    "id": requestId,
                    "error": ["code": -32602, "message": "Missing 'name' in tools/call"]
                ]
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let toolResult = await executeTool(name: toolName, arguments: args)
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "result": [
                    "content": [
                        ["type": "text", "text": toolResult]
                    ],
                    "isError": false
                ]
            ]

        case "resources/list":
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "result": ["resources": getResourceDefinitions()]
            ]

        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            let content = await readResource(uri: uri)
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "result": [
                    "contents": [
                        ["uri": uri, "mimeType": "application/json", "text": content]
                    ]
                ]
            ]

        default:
            return [
                "jsonrpc": "2.0",
                "id": requestId,
                "error": ["code": -32601, "message": "Method '\(method)' not found"]
            ]
        }
    }

    // MARK: - Tool Definitions

    private func getToolDefinitions() -> [[String: Any]] {
        return [
            [
                "name": "velora_get_status",
                "description": "Get real-time operational status of Velora, network state, battery/charging mode, and storage metrics.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "velora_get_playback_state",
                "description": "Inspect currently playing track, playback state, queue size, progress, and artwork status.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "velora_control_playback",
                "description": "Control playback on the device.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["play", "pause", "toggle", "next", "previous"],
                            "description": "Playback action to execute"
                        ]
                    ],
                    "required": ["action"]
                ]
            ],
            [
                "name": "velora_search_and_play",
                "description": "Search local offline library for a song or artist and start playback immediately.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search term (e.g. 'Clean Bandit', 'In The End', 'Coldplay')"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "velora_get_live_logs",
                "description": "Fetch the most recent in-app debug/info/error logs from AppLogger.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Number of logs to retrieve (default: 50, max: 200)"]
                    ]
                ]
            ],
            [
                "name": "velora_audit_storage",
                "description": "Inspect cached cover art, backdrops, artist portraits, 0-byte negative markers, and asset health.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "velora_purge_negative_cache",
                "description": "Self-heal: Purge all 0-byte negative cache markers and reset AssetRegistry unavailable records.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "velora_trigger_repair_sync",
                "description": "Trigger background library integrity repair sync for all missing offline assets.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "velora_fetch_fanart_for_artist",
                "description": "Forcibly download backdrop and clear logo for a specified artist.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "artist": ["type": "string", "description": "Artist name (e.g. 'Clean Bandit', 'Linkin Park', 'Coldplay')"]
                    ],
                    "required": ["artist"]
                ]
            ],
            [
                "name": "velora_ai_engine_intent",
                "description": "Velora AI Engine high-level intent interpreter. Dispatches natural language music instructions directly into the player.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "Natural language instruction (e.g. 'play my favorite rock songs', 'why is my backdrop blank', 'clean up damaged cache')"]
                    ],
                    "required": ["prompt"]
                ]
            ]
        ]
    }

    // MARK: - Tool Execution

    @MainActor
    private func executeTool(name: String, arguments: [String: Any]) async -> String {
        self.lastActionSummary = "Executed tool: \(name)"

        switch name {
        case "velora_get_status":
            let status = buildQuickStatus()
            return toJSONString(status)

        case "velora_get_playback_state":
            let pm = PlaybackManager.shared
            let track = pm?.currentTrack
            let state: [String: Any] = [
                "isPlaying": pm?.isPlaying ?? false,
                "trackTitle": track?.title ?? "None",
                "artist": track?.artist ?? "None",
                "primaryArtist": track?.primaryArtist ?? "None",
                "album": track?.album ?? "None",
                "duration": track?.durationFormatted ?? "0:00",
                "queueCount": pm?.queue.count ?? 0,
                "hasBackdrop": FanartManager.shared.currentBackdrop != nil,
                "hasClearLogo": FanartManager.shared.currentClearLogo != nil
            ]
            return toJSONString(state)

        case "velora_control_playback":
            let action = arguments["action"] as? String ?? ""
            let pm = PlaybackManager.shared
            switch action {
            case "play":
                if pm?.isPlaying == false { pm?.togglePlayPause() }
                return "Playback started"
            case "pause":
                if pm?.isPlaying == true { pm?.togglePlayPause() }
                return "Playback paused"
            case "toggle":
                pm?.togglePlayPause()
                return "Playback toggled. isPlaying: \(pm?.isPlaying ?? false)"
            case "next":
                pm?.skipForward()
                return "Skipped to next track"
            case "previous":
                pm?.skipBackward()
                return "Returned to previous track"
            default:
                return "Unknown playback action: \(action)"
            }

        case "velora_search_and_play":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return "Missing query"
            }
            let tracks = await DatabaseManager.shared.searchTracks(query: query)
            if let first = tracks.first {
                PlaybackManager.shared?.playTrack(first, context: tracks)
                return "Playing '\(first.title)' by \(first.artist ?? "Unknown") (matched \(tracks.count) tracks)"
            } else {
                return "No matching tracks found in library for '\(query)'"
            }

        case "velora_get_live_logs":
            let limit = min(arguments["limit"] as? Int ?? 50, 200)
            let logs = AppLogger.shared.logs.suffix(limit).map {
                "\($0.timestamp.formatted(date: .omitted, time: .standard)) [\($0.level)] \($0.message)"
            }
            return logs.joined(separator: "\n")

        case "velora_audit_storage":
            let fm = FileManager.default
            let countFiles: (URL) -> (count: Int, zeroByteCount: Int) = { dir in
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
                var total = 0
                var zero = 0
                for file in files {
                    total += 1
                    let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int64 ?? 0
                    if size <= 100 { zero += 1 }
                }
                return (total, zero)
            }
            let backdrops = countFiles(VeloraStorage.backdrops)
            let portraits = countFiles(VeloraStorage.artistPortraits)
            let covers = countFiles(VeloraStorage.coverArt)
            let logos = countFiles(VeloraStorage.clearLogos)
            let trackCount = await DatabaseManager.shared.getTrackCount()

            let audit: [String: Any] = [
                "totalTracksInDB": trackCount,
                "backdrops": ["total": backdrops.count, "corruptedZeroByte": backdrops.zeroByteCount],
                "clearLogos": ["total": logos.count, "corruptedZeroByte": logos.zeroByteCount],
                "artistPortraits": ["total": portraits.count, "corruptedZeroByte": portraits.zeroByteCount],
                "coverArt": ["total": covers.count, "corruptedZeroByte": covers.zeroByteCount],
                "unavailableBackdropsInRegistry": AssetRegistry.shared.unavailableBackdropsCount,
                "unavailableLogosInRegistry": AssetRegistry.shared.unavailableLogosCount
            ]
            return toJSONString(audit)

        case "velora_purge_negative_cache":
            FanartManager.shared.wipeNegativeFanartCaches()
            AssetRegistry.shared.resetFanartUnavailableRecords()
            return "Successfully purged all 0-byte negative markers and cleared false negative asset locks."

        case "velora_trigger_repair_sync":
            SyncManager.shared.startRepairSync()
            return "Repair sync initiated in background. Status: \(SyncManager.shared.repairStatus)"

        case "velora_fetch_fanart_for_artist":
            guard let artist = arguments["artist"] as? String, !artist.isEmpty else {
                return "Missing artist name"
            }
            await FanartManager.shared.downloadBackdropSilently(for: [artist])
            await FanartManager.shared.downloadClearLogoSilently(for: artist)
            let hasBackdrop = FanartManager.shared.hasBackdrop(for: artist)
            let hasLogo = FanartManager.shared.hasClearLogo(for: artist)
            return "Fanart query finished for '\(artist)'. hasBackdrop: \(hasBackdrop), hasClearLogo: \(hasLogo)"

        case "velora_ai_engine_intent":
            guard let prompt = arguments["prompt"] as? String else { return "Missing prompt" }
            return await processIntentPrompt(prompt)

        default:
            return "Tool '\(name)' not implemented."
        }
    }

    // MARK: - AI Engine Natural Language Intent Processor

    @MainActor
    private func processIntentPrompt(_ prompt: String) async -> String {
        let p = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if p.contains("play") {
            let query = p.replacingOccurrences(of: "play", with: "")
                .replacingOccurrences(of: "something by", with: "")
                .replacingOccurrences(of: "track", with: "")
                .replacingOccurrences(of: "song", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                PlaybackManager.shared?.togglePlayPause()
                return "Toggled playback."
            }
            let tracks = await DatabaseManager.shared.searchTracks(query: query)
            if let first = tracks.first {
                PlaybackManager.shared?.playTrack(first, context: tracks)
                return "Playing '\(first.title)' by \(first.artist ?? "Unknown Artist")."
            } else {
                return "Could not find any songs matching '\(query)' in local library."
            }
        } else if p.contains("pause") || p.contains("stop") {
            if PlaybackManager.shared?.isPlaying == true {
                PlaybackManager.shared?.togglePlayPause()
            }
            return "Playback paused."
        } else if p.contains("next") || p.contains("skip") {
            PlaybackManager.shared?.skipForward()
            return "Skipped to next track."
        } else if p.contains("previous") || p.contains("back") {
            PlaybackManager.shared?.skipBackward()
            return "Returned to previous track."
        } else if p.contains("heal") || p.contains("fix") || p.contains("repair") || p.contains("cache") {
            FanartManager.shared.wipeNegativeFanartCaches()
            AssetRegistry.shared.resetFanartUnavailableRecords()
            SyncManager.shared.startRepairSync()
            return "Purged corrupt asset locks and started library repair sync."
        } else if p.contains("status") || p.contains("what is playing") {
            let t = PlaybackManager.shared?.currentTrack
            return "Currently playing: \(t?.title ?? "None") by \(t?.artist ?? "None"). Duration: \(t?.durationFormatted ?? "0:00")"
        }

        return "Intent acknowledged: '\(prompt)'. No specific automation rule matched."
    }

    @MainActor
    private func executeAIEngineIntent(body: Data) async -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            return ["status": "error", "message": "Expected JSON with 'prompt' key"]
        }
        let reply = await processIntentPrompt(prompt)
        return ["status": "success", "response": reply]
    }

    // MARK: - Resources

    private func getResourceDefinitions() -> [[String: Any]] {
        return [
            ["uri": "velora://playback/current", "name": "Current Playback", "mimeType": "application/json"],
            ["uri": "velora://logs/live", "name": "Live Log Stream", "mimeType": "text/plain"],
            ["uri": "velora://library/overview", "name": "Library Overview", "mimeType": "application/json"],
            ["uri": "velora://storage/audit", "name": "Storage Audit", "mimeType": "application/json"]
        ]
    }

    @MainActor
    private func readResource(uri: String) async -> String {
        switch uri {
        case "velora://playback/current":
            let pm = PlaybackManager.shared
            let dict: [String: Any] = [
                "title": pm?.currentTrack?.title ?? "None",
                "artist": pm?.currentTrack?.artist ?? "None",
                "album": pm?.currentTrack?.album ?? "None",
                "isPlaying": pm?.isPlaying ?? false
            ]
            return toJSONString(dict)
        case "velora://logs/live":
            return AppLogger.shared.logs.suffix(100).map { "\($0.timestamp.ISO8601Format()) [\($0.level)] \($0.message)" }.joined(separator: "\n")
        case "velora://library/overview":
            let count = await DatabaseManager.shared.getTrackCount()
            return toJSONString(["trackCount": count])
        case "velora://storage/audit":
            return await executeTool(name: "velora_audit_storage", arguments: [:])
        default:
            return "{}"
        }
    }

    // MARK: - Network Helpers

    func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr else { continue }
            let addrFamily = addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "pdp_ip0" { // Wi-Fi or Cellular
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = hostname.withUnsafeBufferPointer { p in
                        p.baseAddress.map { String(cString: $0) }
                    }
                    if name == "en0" { break } // Prefer Wi-Fi
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }

    private func buildQuickStatus() -> [String: Any] {
        let ip = getLocalIPAddress() ?? "127.0.0.1"
        return [
            "name": "Velora AI Powerhouse",
            "version": "2.0.0",
            "serverPort": serverPort,
            "ipAddress": ip,
            "mcpEndpoint": "http://\(ip):\(serverPort)/mcp",
            "isPlaying": PlaybackManager.shared?.isPlaying ?? false,
            "currentTrack": PlaybackManager.shared?.currentTrack?.title ?? "None",
            "isCharging": DevicePowerMonitor.isPluggedInOrCharging,
            "isNetworkConnected": NetworkMonitor.shared.isConnected
        ]
    }

    private nonisolated func toJSONString(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
