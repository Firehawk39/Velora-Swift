#!/usr/bin/env node
/**
 * Velora MCP Bridge (Node.js)
 * Connects Antigravity, Claude, and external AI agents directly to the Velora iOS App over MCP (JSON-RPC 2.0).
 */

const http = require('http');
const readline = require('readline');

const DEFAULT_URL = process.env.VELORA_URL || 'http://192.168.1.7:8765/mcp';

function sendToVelora(payload, serverUrl) {
    return new Promise((resolve) => {
        try {
            const url = new URL(serverUrl);
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
                timeout: 10000
            }, (res) => {
                let chunks = [];
                res.on('data', chunk => chunks.push(chunk));
                res.on('end', () => {
                    const raw = Buffer.concat(chunks).toString('utf8');
                    try {
                        resolve(JSON.parse(raw));
                    } catch (e) {
                        resolve({
                            jsonrpc: '2.0',
                            id: payload.id || null,
                            error: { code: -32700, message: `Invalid JSON response from Velora: ${raw.slice(0, 100)}` }
                        });
                    }
                });
            });

            req.on('error', (err) => {
                resolve({
                    jsonrpc: '2.0',
                    id: payload.id || null,
                    error: { code: -32000, message: `Connection error to ${serverUrl}: ${err.message}` }
                });
            });

            req.on('timeout', () => {
                req.destroy();
                resolve({
                    jsonrpc: '2.0',
                    id: payload.id || null,
                    error: { code: -32000, message: `Request timed out to ${serverUrl}` }
                });
            });

            req.write(data);
            req.end();
        } catch (err) {
            resolve({
                jsonrpc: '2.0',
                id: payload.id || null,
                error: { code: -32000, message: `Bridge exception: ${err.message}` }
            });
        }
    });
}

async function main() {
    const targetUrl = process.argv[2] || DEFAULT_URL;

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
            const resp = await sendToVelora(req, targetUrl);
            process.stdout.write(JSON.stringify(resp) + '\n');
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
