'use strict';

const {spawn} = require('child_process');
const {WebSocketServer, WebSocket} = require('ws');

const cli = process.argv.slice(2);
if (cli.includes('--help') || cli.includes('-h')) {
  console.log('Usage: node scripts/h264-ws-bridge-from-mjpeg.js [mjpegUrl] [wsPort]');
  console.log('Env: BRIDGE_MJPEG_URL, BRIDGE_WS_PORT, BRIDGE_FPS');
  process.exit(0);
}

const inputUrl = process.env.BRIDGE_MJPEG_URL || cli[0] || 'http://127.0.0.1:8001/';
const outputPort = numberOr(process.env.BRIDGE_WS_PORT || cli[1], 27183);
const targetFps = Math.max(5, Math.min(60, numberOr(process.env.BRIDGE_FPS, 24)));
const keyint = Math.max(5, Math.round(targetFps));

const MAX_CARRY = 1024 * 1024;
let ffmpegProcess = null;
let carry = Buffer.alloc(0);
let shuttingDown = false;
let lastSps = null;
let lastPps = null;

const wss = new WebSocketServer({port: outputPort});

wss.on('listening', () => {
  console.log(`[bridge] H264 websocket listening on ws://127.0.0.1:${outputPort}`);
  console.log(`[bridge] MJPEG input: ${inputUrl}`);
});

wss.on('connection', (ws) => {
  console.log('[bridge] client connected');
  if (lastSps && ws.readyState === WebSocket.OPEN) {
    ws.send(lastSps, {binary: true}, noop);
  }
  if (lastPps && ws.readyState === WebSocket.OPEN) {
    ws.send(lastPps, {binary: true}, noop);
  }
  ws.on('close', () => {
    console.log('[bridge] client disconnected');
  });
});

startTranscoder();

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

function startTranscoder() {
  const args = [
    '-hide_banner',
    '-loglevel',
    'warning',
    '-fflags',
    'nobuffer',
    '-flags',
    'low_delay',
    '-f',
    'mpjpeg',
    '-i',
    inputUrl,
    '-an',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-tune',
    'zerolatency',
    '-pix_fmt',
    'yuv420p',
    '-vf',
    'crop=w=iw-2*gte(iw\\,4):h=ih-2*gte(ih\\,4):x=0:y=0,setsar=1',
    '-profile:v',
    'baseline',
    '-level',
    '3.1',
    '-bf',
    '0',
    '-r',
    String(targetFps),
    '-g',
    String(keyint),
    '-keyint_min',
    String(keyint),
    '-f',
    'h264',
    'pipe:1',
  ];

  console.log(`[bridge] starting ffmpeg: ffmpeg ${args.join(' ')}`);
  ffmpegProcess = spawn('ffmpeg', args, {stdio: ['ignore', 'pipe', 'pipe']});

  ffmpegProcess.stdout.on('data', onTranscoderData);
  ffmpegProcess.stderr.on('data', (chunk) => {
    process.stderr.write(String(chunk));
  });
  ffmpegProcess.on('exit', (code, signal) => {
    console.log(`[bridge] ffmpeg exited (code=${code ?? 'null'}, signal=${signal ?? 'null'})`);
    ffmpegProcess = null;
    if (!shuttingDown) {
      setTimeout(startTranscoder, 1200);
    }
  });
  ffmpegProcess.on('error', (err) => {
    console.error(`[bridge] ffmpeg spawn error: ${err.message}`);
  });
}

function onTranscoderData(chunk) {
  carry = Buffer.concat([carry, chunk]);
  processCarry();
}

function processCarry() {
  if (carry.length < 5) {
    return;
  }

  let first = findStartCode(carry, 0);
  if (!first) {
    if (carry.length > MAX_CARRY) {
      carry = carry.subarray(carry.length - 4);
    }
    return;
  }

  if (first.index > 0) {
    carry = carry.subarray(first.index);
    first = {index: 0, length: first.length};
  }

  const starts = [first];
  let cursor = first.index + first.length;
  while (true) {
    const next = findStartCode(carry, cursor);
    if (!next) {
      break;
    }
    starts.push(next);
    cursor = next.index + next.length;
  }

  if (starts.length < 2) {
    if (carry.length > MAX_CARRY) {
      carry = carry.subarray(starts[0].index);
    }
    return;
  }

  for (let i = 0; i < starts.length - 1; i += 1) {
    const start = starts[i];
    const next = starts[i + 1];
    const nal = carry.subarray(start.index, next.index);
    broadcastNal(nal);
  }

  carry = carry.subarray(starts[starts.length - 1].index);
  if (carry.length > MAX_CARRY) {
    carry = carry.subarray(carry.length - 4);
  }
}

function broadcastNal(nal) {
  if (!nal || nal.length < 5) {
    return;
  }
  const startCodeLen = nal[2] === 1 ? 3 : 4;
  const nalType = nal[startCodeLen] & 0x1f;
  if (nalType === 7) {
    lastSps = Buffer.from(nal);
  } else if (nalType === 8) {
    lastPps = Buffer.from(nal);
  }

  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(nal, {binary: true}, noop);
    }
  }
}

function findStartCode(buffer, fromIndex) {
  for (let i = Math.max(0, fromIndex); i < buffer.length - 3; i += 1) {
    if (buffer[i] !== 0x00 || buffer[i + 1] !== 0x00) {
      continue;
    }
    if (buffer[i + 2] === 0x01) {
      return {index: i, length: 3};
    }
    if (buffer[i + 2] === 0x00 && buffer[i + 3] === 0x01) {
      return {index: i, length: 4};
    }
  }
  return null;
}

function shutdown() {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  console.log('[bridge] shutting down');
  for (const client of wss.clients) {
    try {
      client.close(1001, 'server shutdown');
    } catch (_) {
      // no-op
    }
  }
  wss.close();
  if (ffmpegProcess && !ffmpegProcess.killed) {
    ffmpegProcess.kill('SIGTERM');
  }
  setTimeout(() => process.exit(0), 80);
}

function numberOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function noop() {}
