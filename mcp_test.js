const { spawn } = require('child_process');

const navidromeUrl = "http://192.168.1.13:4533";
const navidromeUser = "Harsh";
const navidromePass = "u4vTyG7BcBxR-9-";

const mcp = spawn('npx.cmd', ['-y', 'navidrome-mcp'], {
  shell: true,
  env: {
    ...process.env,
    NAVIDROME_URL: navidromeUrl,
    NAVIDROME_USERNAME: navidromeUser,
    NAVIDROME_PASSWORD: navidromePass
  }
});

let output = '';

mcp.stdout.on('data', (data) => {
  console.log(`Received: ${data}`);
  const lines = data.toString().split('\n');
  for (const line of lines) {
    if (line.trim()) {
      try {
        const msg = JSON.parse(line);
        if (msg.id === 1) {
          console.log('Tools list retrieved.');
          // Now call get_lyrics
          const searchReq = {
            jsonrpc: "2.0",
            id: 2,
            method: "tools/call",
            params: {
              name: "get_lyrics",
              arguments: {
                title: "Chin Check",
                artist: "N.W.A",
                durationMs: 221000
              }
            }
          };
          mcp.stdin.write(JSON.stringify(searchReq) + '\n');
        } else if (msg.id === 2) {
          console.log('Lyrics result:', JSON.stringify(msg.result, null, 2));
          process.exit(0);
        }
      } catch (e) {
        // ignore
      }
    }
  }
});

mcp.stderr.on('data', (data) => {
  console.error(`stderr: ${data}`);
});

mcp.on('close', (code) => {
  console.log(`child process exited with code ${code}`);
});

// Send init
const initReq = {
  jsonrpc: "2.0",
  id: 0,
  method: "initialize",
  params: {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "test", version: "1.0.0" }
  }
};
mcp.stdin.write(JSON.stringify(initReq) + '\n');

setTimeout(() => {
  const listReq = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/list"
  };
  mcp.stdin.write(JSON.stringify(listReq) + '\n');
}, 2000);
