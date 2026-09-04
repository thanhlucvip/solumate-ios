'use strict';

const fs = require('fs');
const crypto = require('crypto');

function printHelp() {
  console.log([
    'Usage:',
    '  node call_wda_swipe_pointarray_secure.js --sid <WDA_SESSION_ID> [--base http://127.0.0.1:8000] [--points-file points.json] [--secret YOUR_SECRET]',
    '  node call_wda_swipe_pointarray_secure.js --auto-sid [--base http://127.0.0.1:8000] [--points-file points.json] [--secret YOUR_SECRET]',
    '  node call_wda_swipe_pointarray_secure.js --list-sessions [--base http://127.0.0.1:8000]',
    '',
    'Options:',
    '  --sid, -s          WDA session id (or "auto")',
    '  --auto-sid         Resolve active WDA session id from /sessions',
    '  --list-sessions    List active WDA sessions and exit',
    '  --no-auto-retry    Disable one-shot retry on invalid session id',
    '  --base, -b         WDA base URL (default: http://127.0.0.1:8000)',
    '  --points-file      JSON file containing pointArray',
    '  --points-json      JSON string containing pointArray',
    '  --secret           Shared secret for HMAC st token',
    '  --st               Raw st token override (legacy / testing)',
    '  --help, -h         Show help',
    '',
    'Examples:',
    '  node call_wda_swipe_pointarray_secure.js --sid 860F... --secret my-secret --points-file ./points.json',
    '  node call_wda_swipe_pointarray_secure.js --sid 860F... --points-json "[[47,430],[48,430,0.06],[51,430,0.068]]" --secret my-secret',
  ].join('\n'));
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    base: process.env.WDA_BASE || 'http://127.0.0.1:8000',
    sid: process.env.WDA_SESSION_ID || '',
    autoSid: false,
    listSessions: false,
    autoRetry: true,
    secret: process.env.SOLUMATE_WDA_SWIPE_SECRET || '',
    st: '',
    pointsFile: '',
    pointsJson: '',
  };

  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    const next = args[i + 1];

    if ((a === '--base' || a === '-b') && next) {
      opts.base = next;
      i += 1;
      continue;
    }
    if ((a === '--sid' || a === '-s') && next) {
      opts.sid = next;
      i += 1;
      continue;
    }
    if (a === '--auto-sid') {
      opts.autoSid = true;
      continue;
    }
    if (a === '--list-sessions') {
      opts.listSessions = true;
      continue;
    }
    if (a === '--no-auto-retry') {
      opts.autoRetry = false;
      continue;
    }
    if (a === '--secret' && next) {
      opts.secret = next;
      i += 1;
      continue;
    }
    if (a === '--st' && next) {
      opts.st = next;
      i += 1;
      continue;
    }
    if (a === '--points-file' && next) {
      opts.pointsFile = next;
      i += 1;
      continue;
    }
    if (a === '--points-json' && next) {
      opts.pointsJson = next;
      i += 1;
      continue;
    }
    if (a === '--help' || a === '-h') {
      printHelp();
      process.exit(0);
    }
  }

  if (opts.sid === 'auto') {
    opts.autoSid = true;
    opts.sid = '';
  }

  if (!opts.listSessions && !opts.sid && !opts.autoSid) {
    throw new Error('Missing --sid <WDA_SESSION_ID> (or use --auto-sid)');
  }
  return opts;
}

function getDefaultPointArray() {
  return [
    [47, 430],
    [48, 430, 0.06],
    [51, 430, 0.068],
    [57, 430, 0.084],
    [71, 430, 0.102],
    [91, 430, 0.118],
    [114, 430, 0.134],
    [135, 431, 0.15],
    [171, 435, 0.166],
    [198, 438, 0.182],
    [229, 441, 0.198],
    [258, 444, 0.213],
    [282, 446, 0.23],
    [293, 447, 0.241],
    [315, 448, 0.26],
    [315, 448, 0.26],
  ];
}

function loadPointArray(opts) {
  if (opts.pointsJson) {
    return JSON.parse(opts.pointsJson);
  }
  if (opts.pointsFile) {
    return JSON.parse(fs.readFileSync(opts.pointsFile, 'utf8'));
  }
  return getDefaultPointArray();
}

function assertFiniteNumber(value, message) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(message);
  }
}

function normalizePointArray(raw) {
  if (!Array.isArray(raw)) {
    throw new Error('pointArray must be an array');
  }
  if (raw.length < 2 || raw.length > 256) {
    throw new Error('pointArray must contain between 2 and 256 points');
  }

  const normalized = [];
  let lastOffset = 0;

  for (let i = 0; i < raw.length; i += 1) {
    const item = raw[i];
    if (!Array.isArray(item) || item.length < 2 || item.length > 3) {
      throw new Error(`pointArray[${i}] must have 2 or 3 numeric values`);
    }

    const x = Number(item[0]);
    const y = Number(item[1]);
    assertFiniteNumber(x, `pointArray[${i}][0] must be a finite number`);
    assertFiniteNumber(y, `pointArray[${i}][1] must be a finite number`);

    let offset = 0;
    if (i === 0) {
      if (item.length === 3) {
        const t0 = Number(item[2]);
        assertFiniteNumber(t0, 'pointArray[0][2] must be a finite number');
        if (Math.abs(t0) > 1e-6) {
          throw new Error('pointArray[0] offset must be 0 or omitted');
        }
      }
      offset = 0;
    } else if (item.length === 3) {
      offset = Number(item[2]);
      assertFiniteNumber(offset, `pointArray[${i}][2] must be a finite number`);
      if (offset < lastOffset) {
        throw new Error(`pointArray[${i}] offset must be monotonic`);
      }
    } else {
      offset = lastOffset + 0.016;
    }

    if (offset > 30) {
      throw new Error('pointArray total duration exceeds 30 seconds');
    }

    lastOffset = offset;
    normalized.push([x, y, offset]);
  }

  return normalized;
}

function formatFixed6(value) {
  return Number(value).toFixed(6);
}

function canonicalPointArray(pointArray) {
  return pointArray
    .map((item) => `${formatFixed6(item[0])},${formatFixed6(item[1])},${formatFixed6(item[2])}`)
    .join(';');
}

function buildSt(pointArray, secret) {
  const ts = String(Math.floor(Date.now() / 1000));
  const message = `${ts}\n${canonicalPointArray(pointArray)}`;
  const sig = crypto.createHmac('sha256', secret).update(message, 'utf8').digest('hex');
  return `${ts}.${sig}`;
}

function extractSessionId(payload) {
  if (!payload) {
    return '';
  }
  if (typeof payload === 'string' && payload.length > 0) {
    return payload;
  }
  if (typeof payload.sessionId === 'string' && payload.sessionId.length > 0) {
    return payload.sessionId;
  }
  if (typeof payload.id === 'string' && payload.id.length > 0) {
    return payload.id;
  }
  if (payload.value && typeof payload.value === 'object') {
    return extractSessionId(payload.value);
  }
  return '';
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, options);
  const data = await res.json().catch(() => ({}));
  return { res, data };
}

function hasErrorPayload(data) {
  return Boolean(data?.value?.error || data?.error);
}

function normalizeSessions(data) {
  const rawList = Array.isArray(data?.value)
    ? data.value
    : Array.isArray(data?.sessions)
      ? data.sessions
      : [];

  const sessions = [];
  for (const item of rawList) {
    const sid = extractSessionId(item);
    if (sid) {
      sessions.push(sid);
    }
  }
  return sessions;
}

async function listActiveSessions(base) {
  const { res, data } = await fetchJson(`${base}/sessions`);
  if (!res.ok || hasErrorPayload(data)) {
    return [];
  }
  return normalizeSessions(data);
}

async function resolveActiveSessionId(base) {
  const sessions = await listActiveSessions(base);
  if (sessions.length > 0) {
    return sessions[0];
  }

  const { res, data } = await fetchJson(`${base}/status`);
  if (res.ok && !hasErrorPayload(data)) {
    const statusSid = extractSessionId(data);
    if (statusSid) {
      return statusSid;
    }
  }
  return '';
}

function isInvalidSessionResponse(res, data) {
  const err = String(data?.value?.error || data?.error || '').toLowerCase();
  const msg = String(data?.value?.message || data?.message || '').toLowerCase();
  const byStatus = res.status === 404 || res.status === 400 || res.status === 500;
  return byStatus && (err.includes('invalid session') || msg.includes('session does not exist'));
}

async function postSwipe(base, sid, payload) {
  const path = `/session/${encodeURIComponent(sid)}/wda/swipe/pointArray`;
  const url = `${base}${path}`;
  const { res, data } = await fetchJson(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  return { sid, path, url, res, data };
}

function printResult(result) {
  console.log(`POST ${result.path}`);
  console.log(`Status: ${result.res.status} ${result.res.statusText}`);
  console.log(JSON.stringify(result.data, null, 2));
}

async function main() {
  const opts = parseArgs(process.argv);
  const base = String(opts.base).replace(/\/+$/, '');

  if (opts.listSessions) {
    const sessions = await listActiveSessions(base);
    if (sessions.length === 0) {
      console.log('No active WDA sessions found.');
      process.exitCode = 1;
      return;
    }
    console.log(`Active sessions (${sessions.length}):`);
    for (const sid of sessions) {
      console.log(`- ${sid}`);
    }
    return;
  }

  const pointArray = normalizePointArray(loadPointArray(opts));
  const st = opts.st || (opts.secret ? buildSt(pointArray, opts.secret) : '');

  let sid = opts.sid;
  if (!sid || opts.autoSid) {
    sid = await resolveActiveSessionId(base);
    if (!sid) {
      throw new Error('No active WDA session found. Create a session first, or pass --sid <WDA_SESSION_ID>.');
    }
    console.log(`resolved_sid=${sid}`);
  }

  const payload = { pointArray };
  if (st) {
    payload.st = st;
  }

  const path = `/session/${encodeURIComponent(sid)}/wda/swipe/pointArray`;
  const url = `${base}${path}`;

  console.log(url);
  console.log(`points=${pointArray.length}`);
  console.log(`duration=${pointArray[pointArray.length - 1][2].toFixed(3)}s`);
  console.log(`auth=${st ? 'yes' : 'no'}`);

  let result = await postSwipe(base, sid, payload);
  printResult(result);

  if (opts.autoRetry && isInvalidSessionResponse(result.res, result.data)) {
    let retrySid = extractSessionId(result.data);
    if (!retrySid || retrySid === sid) {
      retrySid = await resolveActiveSessionId(base);
    }
    if (retrySid && retrySid !== sid) {
      console.log(`retry_sid=${retrySid}`);
      result = await postSwipe(base, retrySid, payload);
      printResult(result);
    }
  }

  if (!result.res.ok || result.data?.value?.error || result.data?.error) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err.message || String(err));
  process.exit(1);
});
