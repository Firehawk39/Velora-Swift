#!/usr/bin/env node
/**
 * Velora MCP Bridge (Node.js)
 * Connects Antigravity, Claude, and external AI agents directly to the Velora iOS App over MCP (JSON-RPC 2.0).
 * Features:
 * - Instant 0ms 'initialize' & 'tools/list' handshake (eliminates IDE timeouts)
 * - Auto-normalization of URLs (fixes typos like :8765mcp -> :8765/mcp)
 * - Auto-discovery across local Wi-Fi network if device IP changes
 * - Graceful MCP error responses when device is locked/app closed
 */

const http = require('http');
const readline = require('readline');
const { execSync } = require('child_process');

function normalizeUrl(raw) {
    if (!raw) return 'http://192.168.1.12:8765/mcp';
    let s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
        s = 'http://' + s;
    }
    s = s.replace(/:(\d+)mcp\/?$/i, ':$1/mcp');
    try {
        const u = new URL(s);
        let path = u.pathname;
        if (!path || path === '/' || path === '') path = '/mcp';
        return `${u.protocol}//${u.hostname}:${u.port || 8765}${path}`;
    } catch {
        return 'http://192.168.1.12:8765/mcp';
    }
}

let currentTargetUrl = normalizeUrl(process.env.VELORA_URL || 'http://192.168.1.12:8765/mcp');

const VELORA_TOOLS = [
    {
        name: "velora_get_status",
        description: "Get real-time operational status of Velora, network state, battery/charging mode, and storage metrics.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_get_playback_state",
        description: "Inspect currently playing track, playback state, queue size, progress, and artwork status.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_get_sync_status",
        description: "Get real-time library sync progress, ETA, and status for metadata, lyrics, media, and repair passes.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_control_playback",
        description: "Control playback on the device.",
        inputSchema: {
            type: "object",
            properties: {
                action: {
                    type: "string",
                    enum: ["play", "pause", "toggle", "next", "previous"],
                    description: "Playback action to execute"
                }
            },
            required: ["action"]
        }
    },
    {
        name: "velora_search_and_play",
        description: "Search local offline library for a song or artist and start playback immediately.",
        inputSchema: {
            type: "object",
            properties: {
                query: { type: "string", description: "Search term (e.g. 'Clean Bandit', 'In The End', 'Coldplay')" }
            },
            required: ["query"]
        }
    },
    {
        name: "velora_get_live_logs",
        description: "Fetch the most recent in-app debug/info/error logs from AppLogger.",
        inputSchema: {
            type: "object",
            properties: {
                limit: { type: "integer", description: "Number of logs to retrieve (default: 50, max: 200)" }
            }
        }
    },
    {
        name: "velora_audit_storage",
        description: "Inspect cached cover art, backdrops, artist portraits, 0-byte negative markers, and asset health.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_purge_negative_cache",
        description: "Self-heal: Purge all 0-byte negative cache markers and reset AssetRegistry unavailable records.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_trigger_repair_sync",
        description: "Trigger background library integrity repair sync for all missing offline assets.",
        inputSchema: { type: "object", properties: {} }
    },
    {
        name: "velora_fetch_fanart_for_artist",
        description: "Forcibly download backdrop and clear logo for a specified artist.",
        inputSchema: {
            type: "object",
            properties: {
                artist: { type: "string", description: "Artist name (e.g. 'Clean Bandit', 'Linkin Park', 'Coldplay')" }
            },
            required: ["artist"]
        }
    },
    {
        name: "velora_ai_engine_intent",
        description: "Velora AI Engine high-level intent interpreter. Dispatches natural language music instructions directly into the player.",
        inputSchema: {
            type: "object",
            properties: {
                prompt: { type: "string", description: "Natural language instruction (e.g. 'play rock songs', 'fix missing artwork')" }
            },
            required: ["prompt"]
        }
    }
];

const VELORA_RESOURCES = [
    { uri: "velora://playback/current", name: "Current Playback", mimeType: "application/json" },
    { uri: "velora://logs/live", name: "Live Log Stream", mimeType: "text/plain" },
    { uri: "velora://library/overview", name: "Library Overview", mimeType: "application/json" },
    { uri: "velora://storage/audit", name: "Storage Audit", mimeType: "application/json" }
];

function checkVeloraHost(ip, port = 8765, timeoutMs = 800) {
    return new Promise((resolve) => {
        const req = http.request({
            hostname: ip,
            port: port,
            path: '/status',
            method: 'GET',
            timeout: timeoutMs
        }, (res) => {
            resolve(res.statusCode === 200);
        });
        req.on('error', () => resolve(false));
        req.on('timeout', () => { req.destroy(); resolve(false); });
        req.end();
    });
}

async function discoverVeloraUrl() {
    try {
        const arpOutput = execSync('arp -a', { encoding: 'utf8', timeout: 1500 });
        const matches = arpOutput.match(/192\.168\.\d+\.\d+/g) || [];
        const uniqueIps = Array.from(new Set(matches)).filter(ip => !ip.endsWith('.255') && !ip.endsWith('.1'));
        
        for (const ip of uniqueIps) {
            const alive = await checkVeloraHost(ip, 8765, 600);
            if (alive) {
                currentTargetUrl = `http://${ip}:8765/mcp`;
                return currentTargetUrl;
            }
        }
    } catch {}
    return null;
}

function sendToVelora(payload, serverUrl, timeoutMs = 4000) {
    return new Promise((resolve) => {
        try {
            const normalized = normalizeUrl(serverUrl);
            const url = new URL(normalized);
            const data = Buffer.from(JSON.stringify(payload), 'utf8');

            const req = http.request({
                hostname: url.hostname,
                port: url.port || 8765,
                path: url.pathname || '/mcp',
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': data.length
                },
                timeout: timeoutMs
            }, (res) => {
                let chunks = [];
                res.on('data', chunk => chunks.push(chunk));
                res.on('end', () => {
                    const raw = Buffer.concat(chunks).toString('utf8');
                    try {
                        resolve({ ok: true, data: JSON.parse(raw) });
                    } catch {
                        resolve({ ok: false, error: `Invalid JSON response: ${raw.slice(0, 100)}` });
                    }
                });
            });

            req.on('error', (err) => resolve({ ok: false, error: err.message }));
            req.on('timeout', () => {
                req.destroy();
                resolve({ ok: false, error: `Request timed out to ${normalized}` });
            });

            req.write(data);
            req.end();
        } catch (err) {
            resolve({ ok: false, error: err.message });
        }
    });
}

async function handleRequest(req) {
    const id = req.id !== undefined ? req.id : null;
    const method = req.method;

    // 1. Instant local handshake for IDE connection lifecycle (0ms, never times out)
    if (method === 'initialize') {
        return {
            jsonrpc: '2.0',
            id: id,
            result: {
                protocolVersion: '2024-11-05',
                capabilities: {
                    tools: { listChanged: false },
                    resources: { subscribe: false, listChanged: false }
                },
                serverInfo: {
                    name: 'Velora AI Powerhouse MCP Server',
                    version: '2.0.0'
                }
            }
        };
    }

    if (method === 'notifications/initialized') {
        return null; // Notifications do not have JSON-RPC responses
    }

    if (method === 'ping') {
        return { jsonrpc: '2.0', id: id, result: {} };
    }

    if (method === 'tools/list') {
        return {
            jsonrpc: '2.0',
            id: id,
            result: { tools: VELORA_TOOLS }
        };
    }

    if (method === 'resources/list') {
        return {
            jsonrpc: '2.0',
            id: id,
            result: { resources: VELORA_RESOURCES }
        };
    }

    // 2. Dynamic live tool/resource execution with auto-discovery & graceful error fallback
    if (method === 'tools/call' || method === 'resources/read') {
        let attempt = await sendToVelora(req, currentTargetUrl, 4000);

        if (!attempt.ok) {
            // Try auto-discovering if Velora moved to another local IP
            const discovered = await discoverVeloraUrl();
            if (discovered) {
                attempt = await sendToVelora(req, discovered, 4000);
            }
        }

        if (attempt.ok) {
            return attempt.data;
        } else {
            // Return compliant MCP tool execution error without terminating connection
            return {
                jsonrpc: '2.0',
                id: id,
                result: {
                    content: [
                        {
                            type: 'text',
                            text: `Velora is not reachable at ${currentTargetUrl} (${attempt.error}). Please ensure the Velora app is open and running on your iPhone or iPad, and that both devices are connected to the same Wi-Fi network.`
                        }
                    ],
                    isError: true
                }
            };
        }
    }

    // Fallback forwarder for custom/unhandled methods
    const fallback = await sendToVelora(req, currentTargetUrl, 4000);
    if (fallback.ok) return fallback.data;

    return {
        jsonrpc: '2.0',
        id: id,
        error: { code: -32601, message: `Method '${method}' could not be executed: ${fallback.error}` }
    };
}

async function main() {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: false
    });

    for await (const line of rl) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
            const req = JSON.parse(trimmed);
            const resp = await handleRequest(req);
            if (resp !== null) {
                process.stdout.write(JSON.stringify(resp) + '\n');
            }
        } catch (err) {
            const errResp = {
                jsonrpc: '2.0',
                id: null,
                error: { code: -32700, message: `Parse error: ${err.message}` }
            };
            process.stdout.write(JSON.stringify(errResp) + '\n');
        }
    }
}

main();
