"use strict";

const fs = require("fs");
const path = require("path");
const http = require("http");
const crypto = require("crypto");

const PORT = Number(3002);
const HOST = process.env.HOST || "127.0.0.1";
const AUTH_TOKEN = String(
  process.env.TRACKPAD_AUTH_TOKEN || process.env.STREAM_AUTH_TOKEN || "",
);
const ALLOWED_ORIGIN = String(process.env.ALLOWED_ORIGIN || "");
const WDA_BASE = String(
  process.env.WDA_BASE || "http://127.0.0.1:8000",
).replace(/\/+$/, "");
const SESSION_ID_API_URL = String(
  process.env.SESSION_ID_API_URL || "http://127.0.0.1:3000/api/session-id",
).trim();
const DEFAULT_SECRET = String(process.env.SOLUMATE_WDA_SWIPE_SECRET || "");
const PAGE_FILE = path.join(__dirname, "trackpad_xsmax.html");
const DEFAULT_SESSION_KEY = "__default__";
const MAX_BODY_BYTES = 1024 * 1024;

const sessionByKey = new Map();
if (process.env.WDA_SESSION_ID) {
  sessionByKey.set(
    DEFAULT_SESSION_KEY,
    String(process.env.WDA_SESSION_ID).trim(),
  );
}

function nowIso() {
  return new Date().toISOString();
}

function log(event, data) {
  const line = `[trackpad-server][${nowIso()}] ${event}`;
  if (data === undefined) {
    console.log(line);
    return;
  }
  console.log(line, data);
}

function setCors(res) {
  res.setHeader("Access-Control-Allow-Origin", ALLOWED_ORIGIN || "*");
  res.setHeader("Access-Control-Allow-Headers", "content-type, authorization");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
}

function sendJson(res, statusCode, payload) {
  setCors(res);
  res.statusCode = statusCode;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.end(JSON.stringify(payload));
}

function sendText(res, statusCode, body, contentType) {
  setCors(res);
  res.statusCode = statusCode;
  res.setHeader("content-type", contentType);
  res.end(body);
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readJsonBody(req) {
  const chunks = [];
  let total = 0;

  for await (const chunk of req) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) {
      throw new Error(`Request body too large (>${MAX_BODY_BYTES} bytes)`);
    }
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    return {};
  }

  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (text.length === 0) {
    return {};
  }

  try {
    const parsed = JSON.parse(text);
    if (parsed === null) {
      return {};
    }
    return parsed;
  } catch (_) {
    throw new Error("Invalid JSON body");
  }
}

function isLikelyUidPath(pathname) {
  const parts = pathname.split("/").filter(Boolean);
  if (parts.length !== 1) {
    return false;
  }
  const seg = parts[0];
  if (!seg || seg.includes(".") || seg.toLowerCase() === "api") {
    return false;
  }
  return true;
}

function toSessionKey(uid) {
  const cleaned = typeof uid === "string" ? uid.trim() : "";
  return cleaned || DEFAULT_SESSION_KEY;
}

function parseUid(urlObj) {
  const fromQuery = String(urlObj.searchParams.get("uid") || "").trim();
  if (fromQuery) {
    return fromQuery;
  }
  const parts = urlObj.pathname.split("/").filter(Boolean);
  if (parts.length > 0) {
    const first = decodeURIComponent(parts[0]);
    if (first && !first.includes(".") && first.toLowerCase() !== "api") {
      return first;
    }
  }
  return "";
}

async function fetchJson(method, routePath, body) {
  const url = `${WDA_BASE}${routePath}`;
  const options = {
    method,
    headers: {},
  };
  if (body !== undefined) {
    options.headers["content-type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  const res = await fetch(url, options);
  const text = await res.text();
  let data = {};
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (_) {
      data = { raw: text };
    }
  }
  return { url, routePath, res, data };
}

function hasWdaError(data) {
  return Boolean(data?.value?.error || data?.error);
}

function wdaErrorCode(data) {
  return String(data?.value?.error || data?.error || "").toLowerCase();
}

function wdaErrorMessage(data) {
  return String(data?.value?.message || data?.message || "").trim();
}

function extractSessionId(payload) {
  if (!payload) {
    return "";
  }
  if (typeof payload === "string" && payload.length > 0) {
    return payload;
  }
  if (typeof payload.sessionId === "string" && payload.sessionId.length > 0) {
    return payload.sessionId;
  }
  if (typeof payload.id === "string" && payload.id.length > 0) {
    return payload.id;
  }
  if (payload.value && typeof payload.value === "object") {
    return extractSessionId(payload.value);
  }
  return "";
}

function isInvalidSession(result) {
  const code = wdaErrorCode(result.data);
  const msg = wdaErrorMessage(result.data).toLowerCase();
  const status = result.res.status;
  if (!(status === 404 || status === 400 || status === 500)) {
    return false;
  }
  return (
    code.includes("invalid session") || msg.includes("session does not exist")
  );
}

function isUnknownCommand(result) {
  const code = wdaErrorCode(result.data);
  const msg = wdaErrorMessage(result.data).toLowerCase();
  if (
    code.includes("unknown command") ||
    code.includes("unsupported operation")
  ) {
    return true;
  }
  if (
    result.res.status === 404 &&
    (msg.includes("unhandled endpoint") || msg.includes("unknown command"))
  ) {
    return true;
  }
  return false;
}

function makeWdaError(result, fallbackMessage) {
  const code = wdaErrorCode(result.data) || "wda_error";
  const message =
    wdaErrorMessage(result.data) ||
    fallbackMessage ||
    `${result.res.status} ${result.res.statusText}`;
  const err = new Error(message);
  err.wdaCode = code;
  err.wdaStatus = result.res.status;
  err.wdaPayload = result.data;
  err.invalidSession = isInvalidSession(result);
  err.unknownCommand = isUnknownCommand(result);
  return err;
}

async function listSessions() {
  const result = await fetchJson("GET", "/sessions");
  if (!result.res.ok || hasWdaError(result.data)) {
    return [];
  }

  const rawSessions = Array.isArray(result.data?.value)
    ? result.data.value
    : Array.isArray(result.data?.sessions)
      ? result.data.sessions
      : [];

  const sessions = [];
  for (const item of rawSessions) {
    const sid = extractSessionId(item);
    if (sid) {
      sessions.push(sid);
    }
  }
  return sessions;
}

function buildSessionApiUrl(uid) {
  if (!SESSION_ID_API_URL) {
    return "";
  }
  try {
    const urlObj = new URL(SESSION_ID_API_URL);
    if (uid && !urlObj.searchParams.has("uid")) {
      urlObj.searchParams.set("uid", uid);
    }
    return urlObj.toString();
  } catch (_) {
    return SESSION_ID_API_URL;
  }
}

async function fetchSessionIdFromApi(uid) {
  const url = buildSessionApiUrl(uid);
  if (!url) {
    return "";
  }

  const res = await fetch(url, { method: "GET" });
  const text = await res.text();
  let data = {};
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (_) {
      throw new Error(`Invalid JSON from session-id API: ${url}`);
    }
  }

  if (!res.ok || data?.ok === false) {
    const msg = String(data?.error || `${res.status} ${res.statusText}`);
    throw new Error(`session-id API failed: ${msg}`);
  }

  const sid = extractSessionId(data);
  if (!sid) {
    throw new Error("session-id API response missing sessionId");
  }
  return sid;
}

function extractScreenSizeFromPayload(data) {
  const root = isPlainObject(data?.value) ? data.value : data;
  if (!isPlainObject(root)) {
    return null;
  }

  if (isPlainObject(root.screenSize)) {
    const width = Number(root.screenSize.width);
    const height = Number(root.screenSize.height);
    if (Number.isFinite(width) && Number.isFinite(height)) {
      return { width, height };
    }
  }

  const width = Number(root.width);
  const height = Number(root.height);
  if (Number.isFinite(width) && Number.isFinite(height)) {
    return { width, height };
  }

  return null;
}

async function getScreenSize(sid) {
  const encodedSid = encodeURIComponent(sid);
  const tries = [
    `/session/${encodedSid}/window/size`,
    `/session/${encodedSid}/wda/screen`,
  ];

  let lastErr = null;
  for (const routePath of tries) {
    const result = await fetchJson("GET", routePath);
    if (result.res.ok && !hasWdaError(result.data)) {
      const size = extractScreenSizeFromPayload(result.data);
      if (size) {
        return size;
      }
      continue;
    }

    const err = makeWdaError(result, "Unable to read screen size");
    if (err.invalidSession) {
      throw err;
    }
    lastErr = err;
  }

  if (lastErr) {
    throw lastErr;
  }

  return null;
}

async function createSession() {
  const payloads = [
    {
      capabilities: {
        alwaysMatch: {
          platformName: "iOS",
          "appium:automationName": "XCUITest",
        },
        firstMatch: [{}],
      },
    },
    {
      desiredCapabilities: {
        platformName: "iOS",
        automationName: "XCUITest",
      },
    },
    {},
  ];

  let lastErr = null;
  for (const payload of payloads) {
    const result = await fetchJson("POST", "/session", payload);
    if (result.res.ok && !hasWdaError(result.data)) {
      const sid = extractSessionId(result.data);
      if (sid) {
        return sid;
      }
    }
    lastErr = makeWdaError(result, "Unable to create WDA session");
  }

  throw lastErr || new Error("Unable to create WDA session");
}

async function ensureSession(sessionKey, uid) {
  const cachedSid = sessionByKey.get(sessionKey);
  if (cachedSid) {
    try {
      const size = await getScreenSize(cachedSid);
      return { sid: cachedSid, screenSize: size, source: "cache" };
    } catch (err) {
      if (err.invalidSession) {
        sessionByKey.delete(sessionKey);
      } else {
        throw err;
      }
    }
  }

  try {
    const sidFromApi = await fetchSessionIdFromApi(uid);
    if (sidFromApi) {
      const size = await getScreenSize(sidFromApi);
      sessionByKey.set(sessionKey, sidFromApi);
      return { sid: sidFromApi, screenSize: size, source: "session-api" };
    }
  } catch (err) {
    log("session-api.warn", { uid: uid || null, error: err.message });
  }

  const activeSessions = await listSessions();
  for (const sid of activeSessions) {
    try {
      const size = await getScreenSize(sid);
      sessionByKey.set(sessionKey, sid);
      return { sid, screenSize: size, source: "sessions" };
    } catch (err) {
      if (!err.invalidSession) {
        throw err;
      }
    }
  }

  const sid = await createSession();
  sessionByKey.set(sessionKey, sid);
  const size = await getScreenSize(sid).catch(() => null);
  return { sid, screenSize: size, source: "new" };
}

async function withSessionRetry(sessionKey, uid, fn) {
  let current = await ensureSession(sessionKey, uid);
  try {
    return await fn(current.sid, current.screenSize);
  } catch (err) {
    if (!err.invalidSession) {
      throw err;
    }
    sessionByKey.delete(sessionKey);
  }

  current = await ensureSession(sessionKey, uid);
  return fn(current.sid, current.screenSize);
}

function formatFixed6(value) {
  return Number(value).toFixed(6);
}

function canonicalPointArray(pointArray) {
  return pointArray
    .map(
      (row) =>
        `${formatFixed6(row[0])},${formatFixed6(row[1])},${formatFixed6(row[2] ?? 0)}`,
    )
    .join(";");
}

function buildSt(pointArray, secret) {
  const ts = String(Math.floor(Date.now() / 1000));
  const message = `${ts}\n${canonicalPointArray(pointArray)}`;
  const sig = crypto
    .createHmac("sha256", secret)
    .update(message, "utf8")
    .digest("hex");
  return `${ts}.${sig}`;
}

function normalizePointArray(raw) {
  if (!Array.isArray(raw)) {
    throw new Error("pointArray must be an array");
  }
  if (raw.length < 2 || raw.length > 256) {
    throw new Error("pointArray must contain between 2 and 256 points");
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
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      throw new Error(`pointArray[${i}] coordinates must be finite`);
    }

    let offset = 0;
    if (i === 0) {
      offset = 0;
      if (item.length === 3) {
        const t0 = Number(item[2]);
        if (!Number.isFinite(t0) || Math.abs(t0) > 1e-6) {
          throw new Error("pointArray[0] offset must be 0 or omitted");
        }
      }
    } else if (item.length === 3) {
      offset = Number(item[2]);
      if (!Number.isFinite(offset) || offset < lastOffset) {
        throw new Error(`pointArray[${i}] offset must be monotonic`);
      }
    } else {
      offset = Number((lastOffset + 0.016).toFixed(3));
    }

    if (offset > 30) {
      throw new Error("pointArray total duration exceeds 30 seconds");
    }

    lastOffset = offset;
    normalized.push([x, y, offset]);
  }

  return normalized;
}

async function forwardPointArray(sid, body) {
  const pointArray = normalizePointArray(body?.pointArray);
  const routePath = `/session/${encodeURIComponent(sid)}/wda/swipe/pointArray`;
  const payload = { pointArray };
  const incomingSt = typeof body?.st === "string" ? body.st.trim() : "";
  const secret =
    typeof body?.secret === "string" ? body.secret.trim() : DEFAULT_SECRET;

  if (incomingSt) {
    payload.st = incomingSt;
  } else if (secret) {
    payload.st = buildSt(pointArray, secret);
  }

  const result = await fetchJson("POST", routePath, payload);
  if (!result.res.ok || hasWdaError(result.data)) {
    throw makeWdaError(result, "WDA pointArray failed");
  }

  return {
    sessionId: sid,
    command: "/wda/swipe/pointArray",
    value: result.data?.value ?? result.data ?? null,
  };
}

async function forwardTap(sid, body) {
  const x = Number(body?.x);
  const y = Number(body?.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    throw new Error("tap requires numeric x and y");
  }

  const payload = { x, y };
  if (Number.isFinite(Number(body?.duration))) {
    payload.duration = Number(body.duration);
  }
  if (typeof body?.st === "string" && body.st.trim()) {
    payload.st = body.st.trim();
  }

  const encodedSid = encodeURIComponent(sid);
  const routes = [
    `/session/${encodedSid}/wda/tap/0`,
    `/session/${encodedSid}/tap/0`,
    `/session/${encodedSid}/wda/tap`,
  ];

  let lastErr = null;
  for (const routePath of routes) {
    const result = await fetchJson("POST", routePath, payload);
    if (result.res.ok && !hasWdaError(result.data)) {
      return {
        sessionId: sid,
        command: routePath.replace(`/session/${encodedSid}`, ""),
        result: true,
        value: result.data?.value ?? result.data ?? null,
      };
    }

    const err = makeWdaError(result, "WDA tap failed");
    if (err.invalidSession) {
      throw err;
    }
    if (err.unknownCommand) {
      lastErr = err;
      continue;
    }
    throw err;
  }

  throw lastErr || new Error("No usable tap endpoint found on this WDA build");
}

function summarizeSessions() {
  const pairs = [];
  for (const [key, sid] of sessionByKey.entries()) {
    pairs.push({ key, sessionId: sid });
  }
  return pairs;
}

function shouldServePage(pathname) {
  return (
    pathname === "/" ||
    pathname === "/trackpad_xsmax.html" ||
    isLikelyUidPath(pathname)
  );
}

async function handleApi(req, res, urlObj) {
  const pathname = urlObj.pathname;
  const uid = parseUid(urlObj);
  const sessionKey = toSessionKey(uid);

  if (req.method === "POST" && pathname === "/api/connect") {
    try {
      const result = await ensureSession(sessionKey, uid);
      const screen = result.screenSize
        ? {
            screenSize: {
              width: result.screenSize.width,
              height: result.screenSize.height,
            },
          }
        : null;
      sendJson(res, 200, {
        ok: true,
        uid: uid || null,
        sessionId: result.sid,
        source: result.source,
        screen,
      });
    } catch (err) {
      log("connect.error", { uid: uid || null, error: err.message });
      sendJson(res, 500, { ok: false, error: err.message || "Connect failed" });
    }
    return true;
  }

  if (req.method === "POST" && pathname === "/api/point-array") {
    try {
      const body = await readJsonBody(req);
      const result = await withSessionRetry(sessionKey, uid, (sid) =>
        forwardPointArray(sid, body),
      );
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      log("point-array.error", { uid: uid || null, error: err.message });
      sendJson(res, 400, {
        ok: false,
        error: err.message || "point-array failed",
      });
    }
    return true;
  }

  if (req.method === "POST" && pathname === "/api/tap") {
    try {
      const body = await readJsonBody(req);
      const result = await withSessionRetry(sessionKey, uid, (sid) =>
        forwardTap(sid, body),
      );
      sendJson(res, 200, { ok: true, ...result });
    } catch (err) {
      log("tap.error", { uid: uid || null, error: err.message });
      sendJson(res, 400, { ok: false, error: err.message || "tap failed" });
    }
    return true;
  }

  if (req.method === "POST" && pathname === "/api/trackpad-log") {
    try {
      const body = await readJsonBody(req);
      log("trackpad.log", {
        uid: uid || null,
        event: body?.event || null,
        ts: body?.ts || null,
        data: body?.data || null,
      });
      sendJson(res, 200, { ok: true });
    } catch (err) {
      sendJson(res, 200, { ok: true });
    }
    return true;
  }

  if (req.method === "GET" && pathname === "/api/state") {
    sendJson(res, 200, {
      ok: true,
      wdaBase: WDA_BASE,
      sessionIdApiUrl: SESSION_ID_API_URL || null,
      sessionCache: summarizeSessions(),
    });
    return true;
  }

  return false;
}

const server = http.createServer(async (req, res) => {
  setCors(res);

  if (req.method === "OPTIONS") {
    res.statusCode = 204;
    res.end();
    return;
  }

  const urlObj = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const pathname = urlObj.pathname;

  if (!isAllowedOrigin(req)) {
    sendJson(res, 403, { ok: false, error: "Origin is not allowed" });
    return;
  }

  if (isProtectedPath(pathname) && !isAuthorized(req, urlObj)) {
    sendUnauthorized(res);
    return;
  }

  if (req.method === "GET" && pathname === "/health") {
    sendJson(res, 200, { ok: true, time: nowIso(), wdaBase: WDA_BASE });
    return;
  }

  if (pathname.startsWith("/api/")) {
    const handled = await handleApi(req, res, urlObj);
    if (!handled) {
      sendJson(res, 404, { ok: false, error: "Not found" });
    }
    return;
  }

  if (req.method === "GET" && pathname === "/favicon.ico") {
    res.statusCode = 204;
    res.end();
    return;
  }

  if (req.method === "GET" && shouldServePage(pathname)) {
    try {
      const html = fs.readFileSync(PAGE_FILE, "utf8");
      sendText(res, 200, html, "text/html; charset=utf-8");
    } catch (err) {
      sendJson(res, 500, { ok: false, error: `Cannot read ${PAGE_FILE}` });
    }
    return;
  }

  sendJson(res, 404, { ok: false, error: "Not found" });
});

server.listen(PORT, HOST, () => {
  log("listening", {
    host: HOST,
    port: PORT,
    wdaBase: WDA_BASE,
    sessionIdApiUrl: SESSION_ID_API_URL || null,
    page: "/trackpad_xsmax.html",
    uidPageExample: "/my-device-uid",
    auth: AUTH_TOKEN ? "enabled" : "disabled",
  });
});

function isAllowedOrigin(req) {
  if (!ALLOWED_ORIGIN) {
    return true;
  }
  const origin = req.headers.origin;
  return !origin || origin === ALLOWED_ORIGIN;
}

function isProtectedPath(pathname) {
  return pathname === "/health" || pathname.startsWith("/api/");
}

function isAuthorized(req, urlObj) {
  if (!AUTH_TOKEN) {
    return true;
  }
  return timingSafeStringEqual(extractRequestToken(req, urlObj), AUTH_TOKEN);
}

function extractRequestToken(req, urlObj) {
  const auth = String(req.headers.authorization || "").trim();
  const bearerMatch = auth.match(/^Bearer\s+(.+)$/i);
  if (bearerMatch) {
    return bearerMatch[1].trim();
  }
  const headerToken = String(req.headers["x-auth-token"] || "").trim();
  if (headerToken) {
    return headerToken;
  }
  return String(
    urlObj.searchParams.get("auth") || urlObj.searchParams.get("token") || "",
  ).trim();
}

function timingSafeStringEqual(a, b) {
  const left = Buffer.from(String(a || ""), "utf8");
  const right = Buffer.from(String(b || ""), "utf8");
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function sendUnauthorized(res) {
  res.setHeader("WWW-Authenticate", 'Bearer realm="ios-trackpad"');
  sendJson(res, 401, { ok: false, error: "Unauthorized" });
}
