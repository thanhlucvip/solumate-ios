'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');

loadEnvFile(path.join(__dirname, '.env'));
loadEnvFile(path.join(__dirname, '.env.local'));

const config = {
  host: process.env.HOST || '0.0.0.0',
  port: numberOr(process.env.PORT, 9100),
  policyPath: normalizePath(process.env.SOLUMATE_RUNTIME_POLICY_PATH || '/ios_check_active'),
  signerPath: normalizePath(process.env.SOLUMATE_GESTURE_SIGNER_PATH || '/gesture/sign'),
  launchEnvPath: normalizePath(process.env.SOLUMATE_LAUNCH_ENV_PATH || '/client/launch-env'),
  policyVersion: String(process.env.SOLUMATE_RUNTIME_POLICY_VERSION || '1'),
  policySecret: trimEnv(
    process.env.SOLUMATE_RUNTIME_POLICY_SECRET ||
    process.env.WDA_AUTH_TOKEN ||
    process.env.SECRET_IOS_SOLUMATE_AUTH ||
    '',
  ),
  signerSecret: trimEnv(
    process.env.SOLUMATE_GESTURE_SIGNER_SECRET ||
    process.env.SOLUMATE_RUNTIME_POLICY_SECRET ||
    process.env.SECRET_IOS_SOLUMATE_AUTH ||
    '',
  ),
  launchEnvSecret: trimEnv(process.env.SOLUMATE_LAUNCH_ENV_SECRET || ''),
  gestureHmacSecret: trimEnv(process.env.SOLUMATE_WDA_SWIPE_SECRET || ''),
  gesturePrivateKey: loadGesturePrivateKey(),
  allowUnsigned: booleanOr(process.env.SOLUMATE_RUNTIME_POLICY_ALLOW_UNSIGNED, false),
  allowFingerprintOnly: booleanOr(process.env.SOLUMATE_RUNTIME_POLICY_ALLOW_FINGERPRINT_ONLY, true),
  maxSkewSeconds: clamp(numberOr(process.env.SOLUMATE_RUNTIME_POLICY_MAX_SKEW_SECONDS, 300), 30, 3600),
  nonceTtlMs: clamp(numberOr(process.env.SOLUMATE_RUNTIME_POLICY_NONCE_TTL_MS, 10 * 60 * 1000), 60 * 1000, 24 * 60 * 60 * 1000),
  signerMaxBodyBytes: clamp(numberOr(process.env.SOLUMATE_GESTURE_SIGNER_MAX_BODY_BYTES, 64 * 1024), 1024, 1024 * 1024),
  allowedBuildFingerprints: parseBuildFingerprintList(
    process.env.SOLUMATE_RUNTIME_ALLOWED_BUILD_FINGERPRINTS ||
    process.env.SOLUMATE_RUNTIME_BUILD_FINGERPRINTS ||
    process.env.SOLUMATE_RUNTIME_BUILD_FINGERPRINT ||
    '',
  ),
};

const seenNonces = new Map();
const seenBuildFingerprints = new Set();
const SIGNER_AUTH_VERSION = 'signer-v1';
const LAUNCH_ENV_AUTH_VERSION = 'launch-v1';

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return;
  }
  const content = fs.readFileSync(filePath, 'utf8');
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) {
      continue;
    }
    const eq = line.indexOf('=');
    if (eq === -1) {
      continue;
    }
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

function trimEnv(value) {
  return String(value || '').trim();
}

function booleanOr(value, fallback) {
  if (typeof value !== 'string') {
    return fallback;
  }
  const normalized = value.trim().toLowerCase();
  if (!normalized) {
    return fallback;
  }
  return ['1', 'true', 'yes', 'on'].includes(normalized);
}

function numberOr(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function normalizeBuildFingerprint(value) {
  let normalized = trimEnv(value).toLowerCase();
  if (!normalized) {
    return '';
  }
  if (normalized.startsWith('sha256:')) {
    normalized = `v1:${normalized.slice('sha256:'.length)}`;
  } else if (!normalized.startsWith('v1:') && !normalized.startsWith('v2:') && !normalized.startsWith('v3:')) {
    normalized = `v1:${normalized}`;
  }
  return /^v[123]:[0-9a-f]{64}$/.test(normalized) ? normalized : '';
}

function parseBuildFingerprintList(value) {
  const result = new Set();
  for (const item of String(value || '').split(/[\s,;]+/)) {
    const normalized = normalizeBuildFingerprint(item);
    if (normalized) {
      result.add(normalized);
    }
  }
  return result;
}

function normalizePath(value) {
  const normalized = String(value || '').trim();
  if (!normalized) {
    return '/ios_check_active';
  }
  return normalized.startsWith('/') ? normalized : `/${normalized}`;
}

function loadGesturePrivateKey() {
  const rawInline = trimEnv(process.env.SOLUMATE_WDA_GESTURE_PRIVATE_KEY || '');
  const keyPath = trimEnv(process.env.SOLUMATE_WDA_GESTURE_PRIVATE_KEY_PATH || '');
  if (!rawInline && !keyPath) {
    return null;
  }
  let material = rawInline;
  if (!material && keyPath) {
    material = fs.readFileSync(path.resolve(keyPath), 'utf8');
  }
  material = String(material || '').replace(/\\n/g, '\n').trim();
  if (!material) {
    return null;
  }
  const key = crypto.createPrivateKey(material);
  if (
    key.asymmetricKeyType !== 'ec' ||
    key.asymmetricKeyDetails?.namedCurve !== 'prime256v1'
  ) {
    throw new Error('SOLUMATE_WDA_GESTURE_PRIVATE_KEY must be an EC P-256 private key');
  }
  return key;
}

function hexFromBuffer(buffer) {
  return Buffer.from(buffer).toString('hex');
}

function canonicalMessage(ts, nonce, reqPath) {
  return `v1\n${ts}\n${nonce}\n${reqPath}`;
}

function sign(secret, ts, nonce, reqPath) {
  return crypto.createHmac('sha256', secret).update(canonicalMessage(ts, nonce, reqPath), 'utf8').digest('hex');
}

function signerAuthMessage(ts, nonce, reqPath, messageHash) {
  return [SIGNER_AUTH_VERSION, ts, nonce, reqPath, messageHash].join('\n');
}

function signSignerAuth(secret, ts, nonce, reqPath, messageHash) {
  return crypto.createHmac('sha256', secret).update(signerAuthMessage(ts, nonce, reqPath, messageHash), 'utf8').digest('hex');
}

function launchEnvAuthMessage(ts, nonce, reqPath) {
  return [LAUNCH_ENV_AUTH_VERSION, ts, nonce, reqPath].join('\n');
}

function signLaunchEnvAuth(secret, ts, nonce, reqPath) {
  return crypto
    .createHmac('sha256', secret)
    .update(launchEnvAuthMessage(ts, nonce, reqPath), 'utf8')
    .digest('hex');
}

function extractRawP256PublicKey(spkiDer) {
  const der = Buffer.from(spkiDer);
  const marker = Buffer.from([0x03, 0x42, 0x00, 0x04]);
  const markerOffset = der.indexOf(marker);
  if (markerOffset < 0 || der.length < markerOffset + marker.length + 64) {
    return '';
  }
  return der.subarray(markerOffset + 3, markerOffset + 3 + 65).toString('base64url');
}

function gesturePublicKeyValue() {
  if (config.gesturePrivateKey) {
    try {
      const publicKey = crypto
        .createPublicKey(config.gesturePrivateKey)
        .export({ type: 'spki', format: 'der' });
      const derived = extractRawP256PublicKey(publicKey);
      if (derived) {
        return derived;
      }
    } catch (_) {
      // Fall through to the explicitly configured public key, if any.
    }
  }
  return trimEnv(process.env.SOLUMATE_WDA_GESTURE_PUBLIC_KEY || '');
}

function timingSafeHexEqual(a, b) {
  const left = Buffer.from(String(a || '').toLowerCase(), 'hex');
  const right = Buffer.from(String(b || '').toLowerCase(), 'hex');
  if (left.length === 0 || right.length === 0 || left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(left, right);
}

function cleanupNonces(nowMs) {
  for (const [nonce, expiresAt] of seenNonces.entries()) {
    if (expiresAt <= nowMs) {
      seenNonces.delete(nonce);
    }
  }
}

function readHeader(req, name) {
  const value = req.headers[String(name).toLowerCase()];
  return Array.isArray(value) ? value[0] : value;
}

function readQuery(urlObj, name) {
  return urlObj.searchParams.get(name);
}

function pickRequestField(req, urlObj, headerName, queryName) {
  const headerValue = trimEnv(readHeader(req, headerName));
  if (headerValue) {
    return headerValue;
  }
  const queryValue = trimEnv(readQuery(urlObj, queryName));
  return queryValue || '';
}

function compactLogValue(value, maxLength = 96) {
  const text = trimEnv(value)
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[^\x20-\x7e]/g, '?');
  if (!text) {
    return '-';
  }
  return text.length > maxLength ? `${text.slice(0, maxLength - 3)}...` : text;
}

function requestClientIp(req) {
  const forwardedFor = trimEnv(readHeader(req, 'x-forwarded-for'));
  return compactLogValue(
    readHeader(req, 'cf-connecting-ip') ||
    (forwardedFor ? forwardedFor.split(',')[0] : '') ||
    readHeader(req, 'x-real-ip') ||
    req.socket?.remoteAddress ||
    '',
    64,
  );
}

function shortBuildFingerprint(value) {
  const normalized = normalizeBuildFingerprint(value);
  if (!normalized) {
    return compactLogValue(value, 48);
  }
  return `${normalized.slice(0, 15)}...${normalized.slice(-8)}`;
}

function logRuntimePolicyCheck(req, statusCode, payload, fingerprint) {
  const state = payload && payload.active === true ? 'ALLOW' : 'DENY';
  const policy = compactLogValue(payload && payload.policy ? payload.policy : '-', 48);
  const error = payload && payload.error ? ` error=${compactLogValue(payload.error, 80)}` : '';
  const fields = [
    `[ios_check_active] ${new Date().toISOString()}`,
    state,
    `http=${statusCode}`,
    `policy=${policy}`,
    `ip=${requestClientIp(req)}`,
    `device=${compactLogValue(readHeader(req, 'x-solumate-device-id'), 64)}`,
    `bundle=${compactLogValue(readHeader(req, 'x-solumate-bundle-id'), 96)}`,
    `os=${compactLogValue(readHeader(req, 'x-solumate-device-os'), 48)}`,
    `model=${compactLogValue(readHeader(req, 'x-solumate-device-model'), 48)}`,
    `fp=${shortBuildFingerprint(fingerprint || pickRequestField(req, new URL(req.url || '/', 'http://localhost'), 'x-solumate-build-fingerprint', 'bf'))}`,
    `ua=${compactLogValue(readHeader(req, 'user-agent'), 96)}`,
  ];
  console.log(`${fields.join(' ')}${error}`);
}

function policyJson(req, res, statusCode, payload, fingerprint = '') {
  logRuntimePolicyCheck(req, statusCode, payload, fingerprint);
  json(res, statusCode, payload);
}

function validateBuildFingerprint(req, urlObj) {
  const rawFingerprint = pickRequestField(req, urlObj, 'x-solumate-build-fingerprint', 'bf');
  const fingerprint = normalizeBuildFingerprint(rawFingerprint);
  if (fingerprint && !seenBuildFingerprints.has(fingerprint) && config.allowedBuildFingerprints.size === 0) {
    seenBuildFingerprints.add(fingerprint);
    console.log(`observed build fingerprint: ${shortBuildFingerprint(fingerprint)}`);
  }

  if (config.allowedBuildFingerprints.size === 0) {
    return { ok: true, fingerprint };
  }
  if (!fingerprint) {
    return { ok: false, statusCode: 401, error: 'build fingerprint missing', fingerprint: rawFingerprint };
  }
  if (!config.allowedBuildFingerprints.has(fingerprint)) {
    return { ok: false, statusCode: 401, error: 'build fingerprint mismatch', fingerprint };
  }
  return { ok: true, fingerprint };
}

function validateLaunchEnvAuth(req, urlObj, nowMs) {
  if (config.launchEnvSecret.length === 0) {
    return { ok: false, statusCode: 503, error: 'launch env secret missing' };
  }

  const ts = pickRequestField(req, urlObj, 'x-solumate-launch-timestamp', 'ts');
  const nonce = pickRequestField(req, urlObj, 'x-solumate-launch-nonce', 'nonce');
  const signature = pickRequestField(req, urlObj, 'x-solumate-launch-signature', 'sig');
  const version = pickRequestField(req, urlObj, 'x-solumate-launch-version', 'v') || LAUNCH_ENV_AUTH_VERSION;

  if (version !== LAUNCH_ENV_AUTH_VERSION) {
    return { ok: false, statusCode: 401, error: 'unsupported launch env auth version' };
  }
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) {
    return { ok: false, statusCode: 401, error: 'invalid launch env timestamp' };
  }
  const skew = Math.abs(Math.floor(nowMs / 1000) - Math.floor(tsNum));
  if (skew > config.maxSkewSeconds) {
    return { ok: false, statusCode: 401, error: 'launch env timestamp expired' };
  }
  if (!nonce) {
    return { ok: false, statusCode: 401, error: 'missing launch env nonce' };
  }
  const nonceKey = `launch:${nonce}`;
  if (seenNonces.has(nonceKey)) {
    return { ok: false, statusCode: 401, error: 'replayed launch env nonce' };
  }
  const expected = signLaunchEnvAuth(config.launchEnvSecret, ts, nonce, urlObj.pathname);
  if (!timingSafeHexEqual(expected, signature)) {
    return { ok: false, statusCode: 401, error: 'launch env signature mismatch' };
  }
  seenNonces.set(nonceKey, nowMs + config.nonceTtlMs);
  return { ok: true };
}

function addLaunchEnv(target, key, value) {
  const trimmed = trimEnv(value);
  if (trimmed) {
    target[key] = trimmed;
  }
}

function buildLaunchEnv() {
  const env = {};
  const externalPolicyURL = trimEnv(
    process.env.SOLUMATE_LAUNCH_RUNTIME_POLICY_URL ||
    process.env.SOLUMATE_RUNTIME_POLICY_URL ||
    process.env.SOLUMATE_IOS_CHECK_ACTIVE_URL ||
    '',
  );
  addLaunchEnv(
    env,
    'SOLUMATE_RUNTIME_POLICY_URL',
    externalPolicyURL || `https://active.solumate.vn${config.policyPath}`,
  );
  addLaunchEnv(env, 'SOLUMATE_RUNTIME_POLICY_SECRET', config.policySecret);
  addLaunchEnv(
    env,
    'SOLUMATE_RUNTIME_POLICY_REFRESH_SECONDS',
    process.env.SOLUMATE_RUNTIME_POLICY_REFRESH_SECONDS || '30',
  );
  addLaunchEnv(
    env,
    'SOLUMATE_RUNTIME_POLICY_MAX_CONSECUTIVE_FAILURES',
    process.env.SOLUMATE_RUNTIME_POLICY_MAX_CONSECUTIVE_FAILURES || '5',
  );
  addLaunchEnv(
    env,
    'SOLUMATE_WDA_ENABLE_POINT_ARRAY',
    process.env.SOLUMATE_WDA_ENABLE_POINT_ARRAY || '1',
  );
  addLaunchEnv(
    env,
    'SOLUMATE_WDA_GESTURE_TOKEN_TTL_SECONDS',
    process.env.SOLUMATE_WDA_GESTURE_TOKEN_TTL_SECONDS || '10',
  );
  addLaunchEnv(
    env,
    'SOLUMATE_WDA_GESTURE_SIGNATURE_MODE',
    process.env.SOLUMATE_WDA_GESTURE_SIGNATURE_MODE ||
      (config.gesturePrivateKey ? 'ecdsa-p256' : 'hmac-v2'),
  );
  addLaunchEnv(env, 'SOLUMATE_WDA_GESTURE_PUBLIC_KEY', gesturePublicKeyValue());
  addLaunchEnv(
    env,
    'SOLUMATE_LOCK_STOCK_GESTURE_ROUTES',
    process.env.SOLUMATE_LOCK_STOCK_GESTURE_ROUTES || '1',
  );

  if (env.SOLUMATE_WDA_GESTURE_SIGNATURE_MODE !== 'ecdsa-p256') {
    addLaunchEnv(env, 'SOLUMATE_WDA_SWIPE_SECRET', config.gestureHmacSecret);
  }

  return env;
}

function handleLaunchEnv(req, res, urlObj) {
  if (req.method !== 'GET') {
    res.setHeader('allow', 'GET');
    text(res, 405, 'method not allowed');
    return;
  }

  const nowMs = Date.now();
  cleanupNonces(nowMs);
  const auth = validateLaunchEnvAuth(req, urlObj, nowMs);
  if (!auth.ok) {
    json(res, auth.statusCode, { ok: false, error: auth.error });
    return;
  }

  json(res, 200, {
    ok: true,
    name: 'secret-ios-solumate',
    version: config.policyVersion,
    env: buildLaunchEnv(),
  });
}

function json(res, statusCode, payload) {
  const body = Buffer.from(`${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  res.statusCode = statusCode;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('cache-control', 'no-store');
  res.setHeader('content-length', String(body.length));
  res.end(body);
}

function text(res, statusCode, body) {
  const buf = Buffer.from(`${body}\n`, 'utf8');
  res.statusCode = statusCode;
  res.setHeader('content-type', 'text/plain; charset=utf-8');
  res.setHeader('cache-control', 'no-store');
  res.setHeader('content-length', String(buf.length));
  res.end(buf);
}

function handlePolicy(req, res, urlObj) {
  if (req.method !== 'GET') {
    res.setHeader('allow', 'GET');
    logRuntimePolicyCheck(req, 405, {
      active: false,
      version: config.policyVersion,
      error: 'method not allowed',
    }, '');
    text(res, 405, 'method not allowed');
    return;
  }

  if (config.allowFingerprintOnly) {
    if (config.allowedBuildFingerprints.size === 0) {
      policyJson(req, res, 503, {
        active: false,
        version: config.policyVersion,
        error: 'build fingerprint lock missing',
      });
      return;
    }
    const buildValidation = validateBuildFingerprint(req, urlObj);
    if (!buildValidation.ok) {
      policyJson(req, res, buildValidation.statusCode, {
        active: false,
        version: config.policyVersion,
        error: buildValidation.error,
      }, buildValidation.fingerprint);
      return;
    }
    policyJson(req, res, 200, {
      active: true,
      version: config.policyVersion,
      policy: 'solumate-fingerprint',
    }, buildValidation.fingerprint);
    return;
  }

  const nowMs = Date.now();
  cleanupNonces(nowMs);
  const signature = pickRequestField(req, urlObj, 'x-solumate-policy-signature', 'sig');

  if (config.policySecret.length === 0 && !config.allowUnsigned) {
    policyJson(req, res, 503, {
      active: false,
      version: config.policyVersion,
      error: 'policy secret missing',
    });
    return;
  }

  if (config.allowUnsigned && config.policySecret.length === 0) {
    const buildValidation = validateBuildFingerprint(req, urlObj);
    if (!buildValidation.ok) {
      policyJson(req, res, buildValidation.statusCode, {
        active: false,
        version: config.policyVersion,
        error: buildValidation.error,
      }, buildValidation.fingerprint);
      return;
    }
    policyJson(req, res, 200, {
      active: true,
      version: config.policyVersion,
      policy: 'unsigned-allowed',
    }, buildValidation.fingerprint);
    return;
  }

  const ts = pickRequestField(req, urlObj, 'x-solumate-policy-timestamp', 'ts');
  const nonce = pickRequestField(req, urlObj, 'x-solumate-policy-nonce', 'nonce');
  const version = pickRequestField(req, urlObj, 'x-solumate-policy-version', 'v') || 'v1';

  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'invalid timestamp' });
    return;
  }

  const skew = Math.abs(Math.floor(nowMs / 1000) - Math.floor(tsNum));
  if (skew > config.maxSkewSeconds) {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'timestamp expired' });
    return;
  }

  if (!nonce) {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'missing nonce' });
    return;
  }

  if (seenNonces.has(nonce)) {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'replayed nonce' });
    return;
  }

  if (version !== 'v1') {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'unsupported version' });
    return;
  }

  const expected = sign(config.policySecret, ts, nonce, urlObj.pathname);
  if (!timingSafeHexEqual(expected, signature)) {
    policyJson(req, res, 401, { active: false, version: config.policyVersion, error: 'signature mismatch' });
    return;
  }

  const buildValidation = validateBuildFingerprint(req, urlObj);
  if (!buildValidation.ok) {
    policyJson(req, res, buildValidation.statusCode, {
      active: false,
      version: config.policyVersion,
      error: buildValidation.error,
    }, buildValidation.fingerprint);
    return;
  }

  seenNonces.set(nonce, nowMs + config.nonceTtlMs);
  policyJson(req, res, 200, {
    active: true,
    version: config.policyVersion,
    policy: 'solumate-runtime',
  }, buildValidation.fingerprint);
}

async function readJsonBody(req, maxBytes) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBytes) {
      const err = new Error(`request body too large (>${maxBytes} bytes)`);
      err.statusCode = 413;
      throw err;
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  const textBody = Buffer.concat(chunks).toString('utf8').trim();
  if (!textBody) {
    return {};
  }
  try {
    const parsed = JSON.parse(textBody);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    const err = new Error('invalid json body');
    err.statusCode = 400;
    throw err;
  }
}

function normalizeGestureVersion(value) {
  const normalized = trimEnv(value).toLowerCase();
  if (normalized === 'v3' || normalized === 'ecdsa' || normalized === 'ecdsa-p256') {
    return 'v3';
  }
  if (normalized === 'v2' || normalized === 'hmac' || normalized === 'hmac-v2') {
    return 'v2';
  }
  return '';
}

function validateSignerAuth(req, urlObj, messageHash, nowMs) {
  if (config.signerSecret.length === 0) {
    return { ok: false, statusCode: 503, error: 'signer secret missing' };
  }

  const ts = pickRequestField(req, urlObj, 'x-solumate-signer-timestamp', 'ts');
  const nonce = pickRequestField(req, urlObj, 'x-solumate-signer-nonce', 'nonce');
  const signature = pickRequestField(req, urlObj, 'x-solumate-signer-signature', 'sig');
  const version = pickRequestField(req, urlObj, 'x-solumate-signer-version', 'v') || SIGNER_AUTH_VERSION;

  if (version !== SIGNER_AUTH_VERSION) {
    return { ok: false, statusCode: 401, error: 'unsupported signer auth version' };
  }
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) {
    return { ok: false, statusCode: 401, error: 'invalid signer timestamp' };
  }
  const skew = Math.abs(Math.floor(nowMs / 1000) - Math.floor(tsNum));
  if (skew > config.maxSkewSeconds) {
    return { ok: false, statusCode: 401, error: 'signer timestamp expired' };
  }
  if (!nonce) {
    return { ok: false, statusCode: 401, error: 'missing signer nonce' };
  }
  const nonceKey = `signer:${nonce}`;
  if (seenNonces.has(nonceKey)) {
    return { ok: false, statusCode: 401, error: 'replayed signer nonce' };
  }
  const expected = signSignerAuth(config.signerSecret, ts, nonce, urlObj.pathname, messageHash);
  if (!timingSafeHexEqual(expected, signature)) {
    return { ok: false, statusCode: 401, error: 'signer signature mismatch' };
  }
  seenNonces.set(nonceKey, nowMs + config.nonceTtlMs);
  return { ok: true };
}

function signGesture(version, message) {
  if (version === 'v3') {
    if (!config.gesturePrivateKey) {
      return { ok: false, statusCode: 503, error: 'gesture private key missing' };
    }
    const signature = crypto
      .sign('sha256', Buffer.from(message, 'utf8'), {
        key: config.gesturePrivateKey,
        dsaEncoding: 'der',
      })
      .toString('base64url');
    return { ok: true, signature };
  }
  if (version === 'v2') {
    if (!config.gestureHmacSecret) {
      return { ok: false, statusCode: 503, error: 'gesture hmac secret missing' };
    }
    const signature = crypto
      .createHmac('sha256', config.gestureHmacSecret)
      .update(message, 'utf8')
      .digest('hex');
    return { ok: true, signature };
  }
  return { ok: false, statusCode: 400, error: 'unsupported gesture version' };
}

async function handleSigner(req, res, urlObj) {
  if (req.method !== 'POST') {
    res.setHeader('allow', 'POST');
    text(res, 405, 'method not allowed');
    return;
  }

  const nowMs = Date.now();
  cleanupNonces(nowMs);
  const body = await readJsonBody(req, config.signerMaxBodyBytes);
  const version = normalizeGestureVersion(body.version);
  const message = typeof body.message === 'string' ? body.message : '';
  if (!version) {
    json(res, 400, { ok: false, error: 'unsupported gesture version' });
    return;
  }
  if (!message) {
    json(res, 400, { ok: false, error: 'missing gesture message' });
    return;
  }
  if (Buffer.byteLength(message, 'utf8') > config.signerMaxBodyBytes) {
    json(res, 413, { ok: false, error: 'gesture message too large' });
    return;
  }

  const messageHash = crypto
    .createHash('sha256')
    .update(message, 'utf8')
    .digest('hex');
  const declaredHash = trimEnv(readHeader(req, 'x-solumate-signer-message-sha256')).toLowerCase();
  if (!timingSafeHexEqual(messageHash, declaredHash)) {
    json(res, 401, { ok: false, error: 'signer message hash mismatch' });
    return;
  }

  const auth = validateSignerAuth(req, urlObj, messageHash, nowMs);
  if (!auth.ok) {
    json(res, auth.statusCode, { ok: false, error: auth.error });
    return;
  }

  const signed = signGesture(version, message);
  if (!signed.ok) {
    json(res, signed.statusCode, { ok: false, error: signed.error });
    return;
  }

  json(res, 200, {
    ok: true,
    version,
    signature: signed.signature,
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const urlObj = new URL(req.url || '/', `http://${req.headers.host || `${config.host}:${config.port}`}`);

    if (req.method === 'GET' && urlObj.pathname === '/healthz') {
      json(res, 200, {
        ok: true,
        name: 'secret-ios-solumate',
        policyPath: config.policyPath,
        signerPath: config.signerPath,
        legacyLaunchEnvPath: config.launchEnvPath,
        buildFingerprintLock: config.allowedBuildFingerprints.size > 0,
        fingerprintOnlyPolicy: config.allowFingerprintOnly,
        signerSecretConfigured: config.signerSecret.length > 0,
        launchEnvSecretConfigured: config.launchEnvSecret.length > 0,
        gesturePrivateKeyConfigured: Boolean(config.gesturePrivateKey),
        gesturePublicKeyConfigured: gesturePublicKeyValue().length > 0,
        gestureHmacSecretConfigured: config.gestureHmacSecret.length > 0,
      });
      return;
    }

    if (urlObj.pathname === config.launchEnvPath) {
      handleLaunchEnv(req, res, urlObj);
      return;
    }

    if (req.method === 'GET' && urlObj.pathname === config.policyPath) {
      handlePolicy(req, res, urlObj);
      return;
    }

    if (urlObj.pathname === config.signerPath) {
      await handleSigner(req, res, urlObj);
      return;
    }

    if (req.method === 'GET' && urlObj.pathname === '/') {
      text(res, 200, 'secret-ios-solumate');
      return;
    }

    text(res, 404, 'not found');
  } catch (error) {
    json(res, error && Number.isInteger(error.statusCode) ? error.statusCode : 500, {
      active: false,
      version: config.policyVersion,
      error: error && error.message ? error.message : 'internal error',
    });
  }
});

server.listen(config.port, config.host, () => {
  console.log(`secret-ios-solumate listening on http://${config.host}:${config.port}${config.policyPath}`);
  console.log(`gesture signer: http://${config.host}:${config.port}${config.signerPath}`);
  console.log(`legacy launch env: http://${config.host}:${config.port}${config.launchEnvPath}`);
  console.log(`policy secret: ${config.policySecret.length > 0 ? 'configured' : 'missing'}`);
  console.log(`signer secret: ${config.signerSecret.length > 0 ? 'configured' : 'missing'}`);
  console.log(`legacy launch env secret: ${config.launchEnvSecret.length > 0 ? 'configured' : 'missing'}`);
  console.log(`gesture private key: ${config.gesturePrivateKey ? 'configured' : 'missing'}`);
  console.log(`gesture public key: ${gesturePublicKeyValue().length > 0 ? 'configured' : 'missing'}`);
  console.log(`fingerprint-only policy: ${config.allowFingerprintOnly ? 'enabled' : 'disabled'}`);
  console.log(`build fingerprint lock: ${config.allowedBuildFingerprints.size > 0 ? `${config.allowedBuildFingerprints.size} allowed` : 'not configured'}`);
});

process.on('SIGINT', () => {
  server.close(() => process.exit(0));
});

process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
