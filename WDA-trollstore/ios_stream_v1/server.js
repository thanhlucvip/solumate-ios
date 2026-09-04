"use strict";

const http = require("http");
const https = require("https");
const net = require("net");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");
const { URL } = require("url");
const { WebSocketServer, WebSocket } = require("ws");

const JPEG_SOI = Buffer.from([0xff, 0xd8]);
const JPEG_EOI = Buffer.from([0xff, 0xd9]);
const MAX_MJPEG_BUFFER_BYTES = 8 * 1024 * 1024;
const MJPEG_WS_MAX_BUFFERED_BYTES = Math.max(
  256 * 1024,
  numberOr(process.env.MJPEG_WS_MAX_BUFFERED_BYTES, 256 * 1024),
);
const MAX_H264_CARRY_BYTES = 4 * 1024 * 1024;
const H264_WS_MAX_BUFFERED_BYTES = Math.max(
  256 * 1024,
  numberOr(process.env.H264_WS_MAX_BUFFERED_BYTES, 384 * 1024),
);
const H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS = Math.max(
  100,
  numberOr(process.env.H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS, 300),
);
const LOCAL_H264_BRIDGE_IDLE_STOP_MS = 12000;
const LOCAL_H264_DECODE_ERROR_RESTART_THRESHOLD = 6;
const LOCAL_H264_DECODE_ERROR_WINDOW_MS = 4000;
const POINT_ARRAY_MAX_POINTS = 256;
const POINT_ARRAY_MAX_DURATION_SECONDS = 30;
const DEFAULT_POINT_ARRAY_SECRET = "SolumateSwipeLocal2026";
const DEFAULT_MJPEG_WDA_SCALE_MAX = 70;
const SETUP_COMMAND_TIMEOUT_MS = 180000;
const SETUP_OUTPUT_LIMIT_BYTES = 4 * 1024 * 1024;

const setupActions = new Map([
  [
    "pair",
    {
      label: "Pair",
      args: ["pair"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "devmode-get",
    {
      label: "Developer Mode: Get",
      args: ["devmode", "get"],
      requiresUdid: true,
      timeoutMs: 30000,
    },
  ],
  [
    "devmode-reveal",
    {
      label: "Developer Mode: Reveal",
      args: ["devmode", "reveal"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "devmode-enable",
    {
      label: "Developer Mode: Enable",
      args: ["devmode", "enable"],
      requiresUdid: true,
      timeoutMs: 120000,
    },
  ],
  [
    "image-list",
    {
      label: "Developer Image: List",
      args: ["image", "list"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "image-auto",
    {
      label: "Developer Image: Auto",
      args: ["image", "auto"],
      requiresUdid: true,
      timeoutMs: 180000,
    },
  ],
  [
    "tunnel-ls",
    {
      label: "Tunnel: List",
      args: ["tunnel", "ls"],
      requiresUdid: false,
      timeoutMs: 30000,
    },
  ],
  [
    "tunnel-start",
    {
      label: "Tunnel: Start",
      args: ["tunnel", "start"],
      requiresUdid: true,
      timeoutMs: 120000,
    },
  ],
  [
    "tunnel-refresh",
    {
      label: "Tunnel: Refresh",
      args: ["tunnel", "refresh"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "tunnel-stop",
    {
      label: "Tunnel: Stop",
      args: ["tunnel", "stop"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "info",
    {
      label: "Device Info",
      args: ["info"],
      requiresUdid: true,
      timeoutMs: 30000,
    },
  ],
  [
    "apps",
    {
      label: "Apps",
      args: ["apps", "--pretty"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
  [
    "profile-list",
    {
      label: "Profiles",
      args: ["profile", "list"],
      requiresUdid: true,
      timeoutMs: 60000,
    },
  ],
]);

loadEnvFile(path.join(__dirname, ".env"));

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "application/javascript; charset=utf-8"],
  [".mjs", "application/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".gif", "image/gif"],
  [".ico", "image/x-icon"],
  [".wasm", "application/wasm"],
  [".txt", "text/plain; charset=utf-8"],
]);

const config = {
  port: parseInt(process.env.PORT || "4200", 10),
  host: process.env.HOST || "0.0.0.0",
  authToken: String(process.env.STREAM_AUTH_TOKEN || ""),
  allowedOrigin: String(process.env.ALLOWED_ORIGIN || ""),
  wdaBase: stripTrailingSlash(process.env.WDA_BASE || "http://127.0.0.1:8000"),
  mjpegUrl: process.env.MJPEG_URL || "http://127.0.0.1:8001",
  webrtcWhepUrl: process.env.WEBRTC_WHEP_URL || "",
  wdaAuthToken: String(
    process.env.WDA_AUTH_TOKEN || process.env.WEBDRIVERAGENT_AUTH_TOKEN || "",
  ),
  realtimeControlHost: process.env.WDA_REALTIME_CONTROL_HOST || "127.0.0.1",
  realtimeControlPort: Math.max(
    1,
    Math.min(65535, numberOr(process.env.WDA_REALTIME_CONTROL_PORT, 8003)),
  ),
  realtimeControlAuthToken: String(
    process.env.WDA_AUTH_TOKEN || process.env.WEBDRIVERAGENT_AUTH_TOKEN || "",
  ),
  realtimeControlConnectTimeoutMs: Math.max(
    250,
    Math.min(10000, numberOr(process.env.WDA_REALTIME_CONTROL_CONNECT_TIMEOUT_MS, 1200)),
  ),
  realtimeTouchDebugEnabled: booleanOr(process.env.WDA_REALTIME_TOUCH_DEBUG, false),
  allowDynamicWsSource: booleanOr(process.env.ALLOW_DYNAMIC_WS_SOURCE, false),
  ffmpegPath: resolveDefaultFfmpegPath(),
  localH264FallbackEnabled: booleanOr(process.env.LOCAL_H264_FALLBACK, true),
  localH264Fps: Math.max(
    10,
    Math.min(60, numberOr(process.env.LOCAL_H264_FPS, 30)),
  ),
  localH264Gop: Math.max(
    10,
    Math.min(180, numberOr(process.env.LOCAL_H264_GOP, 30)),
  ),
  localH264MaxWidth: Math.max(
    240,
    Math.min(1920, numberOr(process.env.LOCAL_H264_MAX_WIDTH, 720)),
  ),
  localH264MaxHeight: Math.max(
    240,
    Math.min(3840, numberOr(process.env.LOCAL_H264_MAX_HEIGHT, 1280)),
  ),
  localH264Encoder: process.env.LOCAL_H264_ENCODER || "libx264",
  pointArraySecret: String(process.env.SOLUMATE_WDA_SWIPE_SECRET || DEFAULT_POINT_ARRAY_SECRET),
  goIosBin: process.env.GO_IOS_BIN || process.env.IOS_BIN || defaultGoIosBin(),
  mjpegWdaScaleMax: Math.max(
    1,
    Math.min(100, numberOr(process.env.MJPEG_WDA_SCALE_MAX, DEFAULT_MJPEG_WDA_SCALE_MAX)),
  ),
  defaultSettings: {
    mjpegServerFramerate: numberOr(process.env.MJPEG_FRAMERATE, 30),
    mjpegScalingFactor: numberOr(process.env.MJPEG_SCALE, 45),
    mjpegServerScreenshotQuality: numberOr(process.env.MJPEG_QUALITY, 20),
    mjpegFixOrientation: booleanOr(process.env.MJPEG_FIX_ORIENTATION, true),
  },
};

function resolveDefaultFfmpegPath() {
  if (process.env.FFMPEG_PATH) {
    return process.env.FFMPEG_PATH;
  }
  return resolveFfmpegStaticPath() || "ffmpeg";
}

function resolveFfmpegStaticPath() {
  try {
    const ffmpegStaticPath = require("ffmpeg-static");
    if (typeof ffmpegStaticPath === "string" && ffmpegStaticPath.length > 0) {
      return ffmpegStaticPath;
    }
  } catch (_) {
    // Optional dependency; fall back to ffmpeg from PATH.
  }
  return "";
}

const state = {
  sessionId: null,
  lastSessionPayload: null,
  createdAt: null,
  realtimeControlConnections: 0,
};

const localH264Bridge = {
  ffmpegAvailable: null,
  ffmpegProbePromise: null,
  process: null,
  clients: new Set(),
  carry: Buffer.alloc(0),
  lastSps: null,
  lastPps: null,
  pendingNals: [],
  pendingHasVcl: false,
  restartTimer: null,
  idleStopTimer: null,
  shuttingDown: false,
  restarting: false,
  lastError: "",
  decodeErrorStreak: 0,
  lastDecodeErrorAt: 0,
};

const publicDir = path.join(__dirname, "public");

const server = http.createServer(async (req, res) => {
  try {
    const reqUrl = new URL(
      req.url,
      `http://${req.headers.host || "localhost"}`,
    );
    if (!isAllowedOrigin(req)) {
      return json(res, 403, { ok: false, error: "Origin is not allowed" });
    }
    if (!isRequestAuthorized(req, reqUrl)) {
      return unauthorized(res);
    }

    if (req.method === "GET" && reqUrl.pathname === "/health") {
      return json(res, 200, {
        ok: true,
        config: {
          port: config.port,
          host: config.host,
          wdaBase: config.wdaBase,
          mjpegUrl: config.mjpegUrl,
          webrtcWhepUrl: config.webrtcWhepUrl || null,
          wdaAuthTokenConfigured: Boolean(config.wdaAuthToken),
          realtimeControlHost: config.realtimeControlHost,
          realtimeControlPort: config.realtimeControlPort,
          realtimeControlAuthTokenConfigured: Boolean(
            config.realtimeControlAuthToken,
          ),
          allowDynamicWsSource: config.allowDynamicWsSource,
          ffmpegPath: config.ffmpegPath,
          localH264FallbackEnabled: config.localH264FallbackEnabled,
          localH264Fps: config.localH264Fps,
          localH264Gop: config.localH264Gop,
          localH264MaxWidth: config.localH264MaxWidth,
          localH264MaxHeight: config.localH264MaxHeight,
          localH264Encoder: config.localH264Encoder,
          mjpegWdaScaleMax: config.mjpegWdaScaleMax,
        },
        localH264Bridge: await getLocalH264BridgeStatus(),
        state,
      });
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/setup/actions") {
      return json(res, 200, {
        ok: true,
        goIosBin: config.goIosBin,
        actions: getSetupActionList(),
      });
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/setup/devices") {
      const result = await runGoIosCommand(["list", "--details"], {
        timeoutMs: 15000,
      });
      return json(res, 200, {
        ok: result.ok,
        command: result.command,
        devices: parseGoIosDeviceList(result.stdout),
        result,
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/setup/run") {
      const body = await readJson(req);
      const actionId =
        typeof body?.action === "string" ? body.action.trim() : "";
      const udid = sanitizeOptionalUdid(body?.udid);
      const action = setupActions.get(actionId);
      if (!action) {
        const err = new Error(`Unsupported setup action: ${actionId || "(empty)"}`);
        err.status = 400;
        throw err;
      }
      if (action.requiresUdid && !udid) {
        const err = new Error(`${action.label} requires UDID`);
        err.status = 400;
        throw err;
      }
      const args = udid ? [`--udid=${udid}`, ...action.args] : action.args;
      const result = await runGoIosCommand(args, {
        timeoutMs: action.timeoutMs,
      });
      return json(res, 200, {
        ok: result.ok,
        action: actionId,
        label: action.label,
        udid: udid || null,
        result,
      });
    }

    if (req.method === "GET" && reqUrl.pathname === "/stream.mjpeg") {
      return proxyMjpeg(req, res);
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/view-modes") {
      return json(res, 200, await buildViewModes());
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/control-modes") {
      return json(res, 200, await buildControlModes());
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/webrtc-offer") {
      const body = await readJson(req);
      const offerSdp = typeof body?.sdp === "string" ? body.sdp.trim() : "";
      if (!offerSdp) {
        const err = new Error("Missing sdp in request body");
        err.status = 400;
        throw err;
      }
      const configuredUrl =
        typeof body?.whepUrl === "string" && body.whepUrl.trim()
          ? body.whepUrl.trim()
          : config.webrtcWhepUrl;
      if (!configuredUrl) {
        const err = new Error("WEBRTC_WHEP_URL is not configured");
        err.status = 400;
        throw err;
      }
      const answer = await createWebRtcAnswer(configuredUrl, offerSdp);
      return json(res, 200, {
        ok: true,
        whepUrl: configuredUrl,
        answerSdp: answer.sdp,
        status: answer.status,
        location: answer.location,
      });
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/status") {
      const status = await wdaFetch("GET", "/status");
      return json(res, 200, unwrapValue(status));
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/screen") {
      const screen = await getScreenInfo();
      return json(res, 200, screen);
    }

    if (req.method === "GET" && reqUrl.pathname === "/api/session-id") {
      const forceRestart = ["1", "true", "yes", "on"].includes(
        String(reqUrl.searchParams.get("forceRestart") || "").toLowerCase(),
      );
      const sessionId = await ensureSession(forceRestart);
      return json(res, 200, {
        ok: true,
        sessionId,
        createdAt: state.createdAt,
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/connect") {
      const body = await readJson(req);
      const forceRestart = Boolean(body?.forceRestart);
      const sessionId = await ensureSession(forceRestart);
      let screen = null;
      let status = null;
      try {
        screen = await getScreenInfo(sessionId);
      } catch (err) {
        screen = { error: err.message };
      }
      try {
        status = unwrapValue(await wdaFetch("GET", "/status"));
      } catch (err) {
        status = { error: err.message };
      }
      const defaultWdaSettings = getDefaultWdaMjpegSettings();
      return json(res, 200, {
        ok: true,
        sessionId,
        screen,
        status,
        settings: toClientMjpegSettings(defaultWdaSettings),
        wdaSettings: defaultWdaSettings,
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/settings") {
      const body = await readJson(req);
      const requestedSettings = sanitizeSettings(body || {});
      const wdaRequestedSettings = toWdaMjpegSettings(requestedSettings);
      const nextSettings = stabilizeMjpegSettingsForScale(wdaRequestedSettings);
      const clientSettings = toClientMjpegSettings(nextSettings, requestedSettings);
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/appium/settings`,
        { settings: nextSettings },
      );
      if (config.localH264FallbackEnabled && localH264Bridge.process) {
        stopLocalH264BridgeProcess("wda settings updated");
      }
      return json(res, 200, {
        ok: true,
        requested: requestedSettings,
        mapped: wdaRequestedSettings,
        sent: nextSettings,
        clientSettings,
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/home") {
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/pressButton`,
        { name: "home" },
      );
      return json(res, 200, { ok: true, result: unwrapValue(result) });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/button") {
      const body = await readJson(req);
      const name =
        typeof body?.name === "string" && body.name.trim()
          ? body.name.trim()
          : "home";
      const duration =
        typeof body?.duration === "number" ? body.duration : undefined;
      const payload = duration == null ? { name } : { name, duration };
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/pressButton`,
        payload,
      );
      return json(res, 200, { ok: true, result: unwrapValue(result) });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/tap") {
      const body = await readJson(req);
      const x = requireNumber(body?.x, "x");
      const y = requireNumber(body?.y, "y");
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/tap`,
        { x, y },
      );
      return json(res, 200, { ok: true, result: unwrapValue(result) });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/touch-down") {
      const body = await readJson(req);
      const payload = normalizeTouchPayload(body, { requirePoint: true });
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/touchDown`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/touchDown",
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/touch-move") {
      const body = await readJson(req);
      const payload = normalizeTouchPayload(body, { requirePoint: true });
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/touchMove`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/touchMove",
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/touch-up") {
      const body = await readJson(req);
      const payload = normalizeTouchPayload(body, { requirePoint: false });
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/touchUp`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/touchUp",
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/touch-cancel") {
      const body = await readJson(req);
      const payload = normalizeTouchPayload(body, { requirePoint: false });
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/touchCancel`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/touchCancel",
        result: unwrapValue(result),
      });
    }

    if (
      (req.method === "GET" || req.method === "POST") &&
      reqUrl.pathname === "/api/hid-probe"
    ) {
      const body = req.method === "POST" ? await readJson(req) : {};
      const queryDispatch = reqUrl.searchParams.get("dispatch");
      const payload = normalizeTouchPayload(
        {
          ...body,
          dispatch:
            typeof body?.dispatch === "boolean"
              ? body.dispatch
              : queryDispatch === "1" || queryDispatch === "true",
        },
        { requirePoint: false },
      );
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/hidProbe`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/hidProbe",
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/point-array") {
      const body = await readJson(req);
      const pointArray = normalizePointArray(body?.pointArray);
      const incomingSt = typeof body?.st === "string" ? body.st.trim() : "";
      const overrideSecret =
        typeof body?.secret === "string" ? body.secret.trim() : "";
      const secret = overrideSecret || config.pointArraySecret;
      const payload = { pointArray };
      if (incomingSt) {
        payload.st = incomingSt;
      } else if (secret) {
        payload.st = buildPointArraySt(pointArray, secret);
      }

      const sessionId = await ensureSession();
      const result = await wdaFetch(
        "POST",
        `/session/${sessionId}/wda/swipe/pointArray`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        sessionId,
        command: "/wda/swipe/pointArray",
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/swipe") {
      const body = await readJson(req);
      const fromX = requireNumber(body?.fromX, "fromX");
      const fromY = requireNumber(body?.fromY, "fromY");
      const toX = requireNumber(body?.toX, "toX");
      const toY = requireNumber(body?.toY, "toY");
      const rawDuration = typeof body?.duration === "number" ? body.duration : 0.03;
      const duration = Number.isFinite(rawDuration)
        ? Math.min(POINT_ARRAY_MAX_DURATION_SECONDS, Math.max(0.01, rawDuration))
        : 0.03;
      const pointArray = [
        [Math.round(fromX), Math.round(fromY), 0],
        [Math.round(toX), Math.round(toY), Number(duration.toFixed(3))],
      ];
      const payload = { pointArray };
      if (config.pointArraySecret) {
        payload.st = buildPointArraySt(pointArray, config.pointArraySecret);
      }
      const result = await wdaFetch(
        "POST",
        `/session/${await ensureSession()}/wda/swipe/pointArray`,
        payload,
      );
      return json(res, 200, {
        ok: true,
        command: "/wda/swipe/pointArray",
        duration,
        result: unwrapValue(result),
      });
    }

    if (req.method === "POST" && reqUrl.pathname === "/api/restart-session") {
      const sessionId = await ensureSession(true);
      return json(res, 200, { ok: true, sessionId });
    }

    if (req.method === "DELETE" && reqUrl.pathname === "/api/session") {
      if (!state.sessionId) {
        return json(res, 200, {
          ok: true,
          deleted: false,
          message: "No active session cached",
        });
      }
      const sessionId = state.sessionId;
      try {
        await wdaFetch("DELETE", `/session/${sessionId}`);
      } catch (_) {
        // Ignore: WDA might already clear session internally.
      }
      state.sessionId = null;
      state.lastSessionPayload = null;
      state.createdAt = null;
      return json(res, 200, { ok: true, deleted: true, sessionId });
    }

    if (req.method === "GET") {
      const filePath =
        reqUrl.pathname === "/"
          ? path.join(publicDir, "index.html")
          : reqUrl.pathname === "/setup"
            ? path.join(publicDir, "setup.html")
          : resolvePublicFilePath(reqUrl.pathname);
      if (filePath) {
        return serveFile(res, filePath, getContentType(filePath));
      }
    }

    return json(res, 404, { ok: false, error: "Not found" });
  } catch (err) {
    const status = err && Number.isInteger(err.status) ? err.status : 500;
    return json(res, status, {
      ok: false,
      error: err.message || "Unknown error",
      details: err.data || null,
    });
  }
});

const wsServer = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  try {
    const reqUrl = new URL(
      req.url,
      `http://${req.headers.host || "localhost"}`,
    );
    if (
      reqUrl.pathname !== "/ws/mjpeg" &&
      reqUrl.pathname !== "/ws/h264" &&
      reqUrl.pathname !== "/ws/realtime-control"
    ) {
      socket.destroy();
      return;
    }
    if (!isAllowedOrigin(req) || !isRequestAuthorized(req, reqUrl)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    wsServer.handleUpgrade(req, socket, head, (ws) => {
      wsServer.emit("connection", ws, req, reqUrl);
    });
  } catch (_) {
    socket.destroy();
  }
});

wsServer.on("connection", (clientSocket, req, reqUrl) => {
  if (!reqUrl || !reqUrl.pathname) {
    closeWsWithError(clientSocket, 4400, "Missing websocket path");
    return;
  }
  if (reqUrl.pathname === "/ws/mjpeg") {
    handleMjpegWsClient(clientSocket, reqUrl);
    return;
  }
  if (reqUrl.pathname === "/ws/h264") {
    handleH264WsClient(clientSocket, reqUrl).catch((err) => {
      closeWsWithError(
        clientSocket,
        4503,
        err.message || "Cannot initialize H264 websocket stream",
      );
    });
    return;
  }
  if (reqUrl.pathname === "/ws/realtime-control") {
    handleRealtimeControlWsClient(clientSocket, reqUrl);
    return;
  }
  closeWsWithError(
    clientSocket,
    4404,
    `Unsupported websocket path: ${reqUrl.pathname}`,
  );
});

server.listen(config.port, config.host, () => {
  console.log(
    `iOS WDA stream server listening on http://${config.host}:${config.port}`,
  );
  console.log(`WDA base: ${config.wdaBase}`);
  console.log(`MJPEG source: ${config.mjpegUrl}`);
  console.log("H264 websocket source: local MJPEG->H264 bridge");
  console.log(`WebRTC WHEP URL: ${config.webrtcWhepUrl || "(not set)"}`);
  console.log(
    `Realtime control: tcp://${config.realtimeControlHost}:${config.realtimeControlPort}`,
  );
  console.log(
    `Realtime control auth token: ${config.realtimeControlAuthToken ? "configured" : "(not set)"}`,
  );
  console.log(
    `Local H264 fallback: ${config.localH264FallbackEnabled ? "enabled" : "disabled"}`,
  );
  if (config.localH264FallbackEnabled) {
    console.log(
      `Local H264 encoder: ${config.localH264Encoder} @ ${config.localH264Fps}fps (gop ${config.localH264Gop}) ${config.localH264MaxWidth}x${config.localH264MaxHeight} via ${config.ffmpegPath}`,
    );
  }
});

process.once("SIGINT", handleShutdownSignal);
process.once("SIGTERM", handleShutdownSignal);

async function ensureSession(forceRestart = false) {
  if (state.sessionId && !forceRestart) {
    return state.sessionId;
  }

  if (state.sessionId && forceRestart) {
    try {
      await wdaFetch("DELETE", `/session/${state.sessionId}`);
    } catch (_) {
      // Best effort only.
    }
    state.sessionId = null;
  }

  const payloads = [
    { capabilities: { alwaysMatch: {}, firstMatch: [{}] } },
    {
      desiredCapabilities: {},
      capabilities: { alwaysMatch: {}, firstMatch: [{}] },
    },
    { capabilities: {} },
  ];

  const errors = [];
  for (const payload of payloads) {
    const response = await rawFetch(
      "POST",
      `${config.wdaBase}/session`,
      payload,
    );
    const sessionId = extractSessionId(response.data);
    if (response.ok && sessionId) {
      state.sessionId = sessionId;
      state.lastSessionPayload = payload;
      state.createdAt = new Date().toISOString();
      try {
        await wdaFetch("POST", `/session/${sessionId}/appium/settings`, {
          settings: getDefaultWdaMjpegSettings(),
        });
      } catch (err) {
        console.warn(
          "Warning: failed to apply initial MJPEG settings:",
          err.message,
        );
      }
      return sessionId;
    }
    errors.push({ status: response.status, data: response.data });
  }

  const last = errors[errors.length - 1] || {};
  const message =
    extractWdaMessage(last.data) || "Failed to create WDA session";
  const err = new Error(message);
  err.status = last.status || 500;
  err.data = { attempts: errors };
  throw err;
}

async function wdaFetch(method, pathname, body) {
  const response = await rawFetch(method, `${config.wdaBase}${pathname}`, body);

  if (!response.ok || isWdaError(response.data)) {
    const message =
      extractWdaMessage(response.data) ||
      `${response.status} ${response.statusText}`;
    const err = new Error(message);
    err.status = response.status;
    err.data = response.data;

    if (
      response.status === 404 &&
      state.sessionId &&
      pathname.includes(`/session/${state.sessionId}/`)
    ) {
      state.sessionId = null;
    }

    if (isInvalidSession(response.data) && pathname.includes("/session/")) {
      state.sessionId = null;
      const retriedPath = pathname.replace(
        /\/session\/[^/]+/,
        `/session/${await ensureSession()}`,
      );
      return wdaFetch(method, retriedPath, body);
    }

    throw err;
  }
  return response.data;
}

function requestText(url, options = {}) {
  const parsedUrl = new URL(url);
  const transport = parsedUrl.protocol === "https:" ? https : http;
  const headers = { ...(options.headers || {}) };
  const payload = options.body;
  const timeoutMs = options.timeoutMs || 20000;

  if (
    payload !== undefined &&
    !Object.keys(headers).some((key) => key.toLowerCase() === "content-length")
  ) {
    headers["content-length"] = Buffer.byteLength(payload);
  }

  return new Promise((resolve, reject) => {
    const req = transport.request(
      {
        protocol: parsedUrl.protocol,
        hostname: parsedUrl.hostname,
        port: parsedUrl.port || undefined,
        path: `${parsedUrl.pathname}${parsedUrl.search}`,
        method: options.method || "GET",
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        });
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          const status = res.statusCode || 0;
          resolve({
            ok: status >= 200 && status < 300,
            status,
            statusText: res.statusMessage || "",
            text,
            headers: res.headers,
          });
        });
      },
    );

    req.on("error", reject);
    req.setTimeout(timeoutMs, () => {
      const err = new Error(`request timed out after ${timeoutMs}ms`);
      err.code = "ETIMEDOUT";
      req.destroy(err);
    });

    if (payload !== undefined) {
      req.write(payload);
    }
    req.end();
  });
}

async function rawFetch(method, url, body) {
  const headers = {};
  Object.assign(headers, wdaAuthHeaders());
  let payload;
  if (body !== undefined) {
    headers["content-type"] = "application/json";
    payload = JSON.stringify(body);
  }

  let response;
  try {
    response = await requestText(url, {
      method,
      headers,
      body: payload,
      timeoutMs: 20000,
    });
  } catch (err) {
    const cause = err?.cause?.message || err?.message || String(err);
    const code = err?.cause?.code || err?.code || null;
    const e = new Error(`Cannot connect to WDA endpoint ${url}: ${cause}`);
    e.status = 502;
    e.data = {
      code,
      cause,
      hint: networkHintForCode(code),
    };
    throw e;
  }

  const text = response.text;
  const data = parseMaybeJson(text);
  return {
    ok: response.ok,
    status: response.status,
    statusText: response.statusText,
    data,
    text,
  };
}

function wdaAuthHeaders(headers = {}) {
  if (!config.wdaAuthToken) {
    return headers;
  }
  return {
    ...headers,
    Authorization: `Bearer ${config.wdaAuthToken}`,
    "X-WDA-Token": config.wdaAuthToken,
  };
}

async function getScreenInfo(inputSessionId) {
  const sessionId = inputSessionId || (await ensureSession());
  let sessionScreen = null;
  let legacyScreen = null;
  let windowSize = null;

  try {
    sessionScreen = unwrapValue(
      await wdaFetch("GET", `/session/${sessionId}/wda/screen`),
    );
  } catch (_) {
    // Not all WDA builds expose this endpoint.
  }

  try {
    legacyScreen = unwrapValue(await wdaFetch("GET", "/wda/screen"));
  } catch (_) {
    // Older/newer WDA can miss this endpoint.
  }

  try {
    windowSize = unwrapValue(
      await wdaFetch("GET", `/session/${sessionId}/window/size`),
    );
  } catch (err) {
    // Fallback for odd implementations.
    try {
      windowSize = unwrapValue(await wdaFetch("GET", "/window/size"));
    } catch (_) {
      throw err;
    }
  }

  const merged = {};
  if (sessionScreen && typeof sessionScreen === "object") {
    Object.assign(merged, sessionScreen);
  }
  if (legacyScreen && typeof legacyScreen === "object") {
    Object.assign(merged, legacyScreen);
  }

  const width = Number(windowSize?.width);
  const height = Number(windowSize?.height);
  if (Number.isFinite(width) && Number.isFinite(height)) {
    merged.screenSize = {
      width: Math.round(width),
      height: Math.round(height),
    };
  }

  if (!merged.screenSize) {
    const err = new Error("Cannot read screenSize from WDA endpoints");
    err.status = 502;
    throw err;
  }
  return merged;
}

function proxyMjpeg(req, res) {
  const upstream = new URL(config.mjpegUrl);
  const transport = upstream.protocol === "https:" ? https : http;
  req.socket?.setNoDelay?.(true);
  res.socket?.setNoDelay?.(true);

  const proxyReq = transport.request(
    {
      protocol: upstream.protocol,
      hostname: upstream.hostname,
      port: upstream.port,
      path: `${upstream.pathname}${upstream.search}`,
      method: "GET",
      headers: wdaAuthHeaders({
        "user-agent": "ios-wda-stream-server/1.0",
        accept: "multipart/x-mixed-replace, image/jpeg, */*",
        connection: "keep-alive",
      }),
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode || 200, {
        "content-type":
          proxyRes.headers["content-type"] || "multipart/x-mixed-replace",
        "cache-control":
          "no-store, no-cache, must-revalidate, proxy-revalidate",
        pragma: "no-cache",
        expires: "0",
        connection: "close",
        "x-accel-buffering": "no",
      });

      proxyRes.pipe(res);
      proxyRes.on("close", () => res.end());
    },
  );
  proxyReq.on("socket", (socket) => {
    socket.setNoDelay?.(true);
  });

  proxyReq.on("error", (err) => {
    json(res, 502, {
      ok: false,
      error: `Cannot connect to MJPEG source at ${config.mjpegUrl}`,
      details: err.message,
    });
  });

  req.on("close", () => proxyReq.destroy());
  proxyReq.end();
}

function handleMjpegWsClient(clientSocket, reqUrl) {
  clientSocket._socket?.setNoDelay?.(true);
  const source = resolveMjpegSource(reqUrl);
  if (!source.ok) {
    closeWsWithError(clientSocket, 4400, source.error);
    return;
  }

  const upstream = new URL(source.url);
  const transport = upstream.protocol === "https:" ? https : http;
  const requestedFps = numberOr(reqUrl.searchParams.get("fps"), 0);
  const minFrameIntervalMs =
    requestedFps > 0 ? Math.max(1, Math.floor(1000 / requestedFps)) : 0;
  let lastFrameAt = 0;
  let carry = Buffer.alloc(0);
  let closed = false;
  let upstreamRes = null;

  const closeResources = () => {
    if (closed) {
      return;
    }
    closed = true;
    if (upstreamRes) {
      upstreamRes.destroy();
      upstreamRes = null;
    }
    if (clientSocket.readyState === WebSocket.OPEN) {
      clientSocket.close(1000, "MJPEG stream closed");
    }
  };

  const upstreamReq = transport.request(
    {
      protocol: upstream.protocol,
      hostname: upstream.hostname,
      port: upstream.port,
      path: `${upstream.pathname}${upstream.search}`,
      method: "GET",
      headers: wdaAuthHeaders({
        "user-agent": "ios-wda-stream-server/1.0",
        accept: "multipart/x-mixed-replace, image/jpeg, */*",
        connection: "keep-alive",
      }),
    },
    (res) => {
      upstreamRes = res;
      if ((res.statusCode || 500) >= 400) {
        closeWsWithError(
          clientSocket,
          4502,
          `MJPEG upstream returned HTTP ${res.statusCode}`,
        );
        return;
      }

      safeWsSendJson(clientSocket, {
        type: "ready",
        mode: "mjpeg-binary",
        source: source.label,
        fps: requestedFps > 0 ? requestedFps : null,
      });

      res.on("data", (chunk) => {
        if (closed || clientSocket.readyState !== WebSocket.OPEN) {
          return;
        }
        carry = Buffer.concat([carry, chunk]);
        const extracted = extractJpegFrames(carry);
        carry = extracted.rest;
        const frame = extracted.frames[extracted.frames.length - 1];
        if (!frame) {
          return;
        }
        const now = Date.now();
        if (
          minFrameIntervalMs > 0 &&
          now - lastFrameAt < minFrameIntervalMs
        ) {
          return;
        }
        if (clientSocket.bufferedAmount > MJPEG_WS_MAX_BUFFERED_BYTES) {
          return;
        }
        lastFrameAt = now;
        if (clientSocket.readyState === WebSocket.OPEN) {
          clientSocket.send(frame, { binary: true }, noop);
        }
      });

      res.on("error", (err) => {
        closeWsWithError(
          clientSocket,
          4503,
          `MJPEG upstream error: ${err.message}`,
        );
      });

      res.on("end", () => {
        if (!closed && clientSocket.readyState === WebSocket.OPEN) {
          clientSocket.close(1011, "MJPEG upstream ended");
        }
      });
    },
  );

  upstreamReq.on("error", (err) => {
    closeWsWithError(
      clientSocket,
      4501,
      `Cannot connect MJPEG upstream: ${err.message}`,
    );
  });

  clientSocket.on("close", () => {
    closed = true;
    upstreamReq.destroy();
    if (upstreamRes) {
      upstreamRes.destroy();
    }
  });

  clientSocket.on("error", () => {
    closeResources();
    upstreamReq.destroy();
  });

  upstreamReq.end();
}

function handleRealtimeControlWsClient(clientSocket) {
  clientSocket._socket?.setNoDelay?.(true);
  const source = `tcp://${config.realtimeControlHost}:${config.realtimeControlPort}`;
  const pendingClientMessages = [];
  let pendingRealtimeMove = null;
  let pendingRealtimeMoveFlushScheduled = false;
  let upstreamWriteBackpressured = false;
  let upstreamSocket = null;
  let upstreamBuffer = "";
  let upstreamReady = false;
  let authPending = false;
  let startupProbePending = false;
  let closed = false;
  let counted = true;
  let timeoutTimer = null;

  state.realtimeControlConnections += 1;

  const decrementConnectionCount = () => {
    if (!counted) {
      return;
    }
    counted = false;
    state.realtimeControlConnections = Math.max(
      0,
      state.realtimeControlConnections - 1,
    );
  };

  const cleanup = () => {
    clearTimeout(timeoutTimer);
    timeoutTimer = null;
    decrementConnectionCount();
    if (upstreamSocket) {
      upstreamSocket.destroy();
      upstreamSocket = null;
    }
  };

  const closeBoth = (code, message) => {
    if (closed) {
      return;
    }
    closed = true;
    cleanup();
    closeWsWithError(clientSocket, code, message);
  };

  const writeToUpstream = (payload) => {
    if (!upstreamSocket || !upstreamSocket.writable) {
      return false;
    }
    if (payload && typeof payload === "object" && payload.serverForwardTimestamp == null) {
      payload.serverForwardTimestamp = Date.now();
    }
    const line = JSON.stringify(payload);
    return upstreamSocket.write(`${line}\n`, noop);
  };

  const logRealtimeInput = (stage, payload, extra = {}) => {
    if (!config.realtimeTouchDebugEnabled) {
      return;
    }
    const normalizedType = normalizeRealtimeControlType(payload?.type || "");
    const logTimestamp = Date.now();
    console.log(
      [
        "[RT INPUT]",
        `stage=${stage}`,
        `type=${normalizedType || "?"}`,
        `seq=${payload?.sequence ?? payload?.seq ?? "-"}`,
        `pointerId=${payload?.pointerId ?? payload?.finger ?? payload?.pointer ?? "-"}`,
        `x=${payload?.x ?? "-"}`,
        `y=${payload?.y ?? "-"}`,
        `clientTs=${payload?.timestamp ?? "-"}`,
        `nodeRecvTs=${payload?.serverReceiveTimestamp ?? "-"}`,
        `nodeForwardTs=${payload?.serverForwardTimestamp ?? "-"}`,
        `nodeLogTs=${logTimestamp}`,
        `wsQueueDepth=${pendingClientMessages.length}`,
        `movePending=${pendingRealtimeMove ? 1 : 0}`,
        `backpressured=${upstreamWriteBackpressured ? 1 : 0}`,
        ...Object.entries(extra).map(([key, value]) => `${key}=${value}`),
      ].join(" "),
    );
  };

  const flushPendingRealtimeMove = () => {
    if (!upstreamReady || !upstreamSocket || !upstreamSocket.writable || pendingRealtimeMove == null) {
      return true;
    }
    const payload = pendingRealtimeMove;
    pendingRealtimeMove = null;
    const ok = writeToUpstream(payload);
    upstreamWriteBackpressured = !ok;
    if (config.realtimeTouchDebugEnabled) {
      logRealtimeInput("flush-move", payload, {
        upstreamOk: ok ? 1 : 0,
      });
    }
    return ok;
  };

  const schedulePendingRealtimeMoveFlush = () => {
    if (pendingRealtimeMoveFlushScheduled || !upstreamReady || upstreamWriteBackpressured) {
      return;
    }
    if (!pendingRealtimeMove || !upstreamSocket || !upstreamSocket.writable) {
      return;
    }
    pendingRealtimeMoveFlushScheduled = true;
    setImmediate(() => {
      pendingRealtimeMoveFlushScheduled = false;
      if (closed || !upstreamReady || upstreamWriteBackpressured) {
        return;
      }
      flushPendingRealtimeMove();
    });
  };

  const startStartupProbe = () => {
    if (closed || !upstreamSocket || !upstreamSocket.writable) {
      return false;
    }
    startupProbePending = true;
    return writeToUpstream({
      type: "ping",
      id: "realtime-startup-probe",
    });
  };

  const flushPendingClientMessages = () => {
    if (
      !upstreamReady ||
      !upstreamSocket ||
      !upstreamSocket.writable ||
      upstreamWriteBackpressured
    ) {
      return;
    }
    while (pendingClientMessages.length > 0) {
      const payload = pendingClientMessages.shift();
      const ok = writeToUpstream(payload);
      upstreamWriteBackpressured = !ok;
      if (config.realtimeTouchDebugEnabled) {
        logRealtimeInput("flush-command", payload, {
          upstreamOk: ok ? 1 : 0,
        });
      }
      if (!ok) {
        return;
      }
    }
    if (pendingRealtimeMove != null) {
      flushPendingRealtimeMove();
    }
  };

  const enqueueClientMessage = (payload, normalizedType) => {
    if (normalizedType === "move") {
      pendingRealtimeMove = payload;
      schedulePendingRealtimeMoveFlush();
      return true;
    }

    if (pendingRealtimeMove != null) {
      if (pendingClientMessages.length >= 256) {
        return false;
      }
      pendingClientMessages.push(pendingRealtimeMove);
      pendingRealtimeMove = null;
    }
    if (pendingClientMessages.length >= 256) {
      return false;
    }
    pendingClientMessages.push(payload);
    flushPendingClientMessages();
    return true;
  };

  const markUpstreamReady = () => {
    if (closed || upstreamReady) {
      return;
    }
    clearTimeout(timeoutTimer);
    timeoutTimer = null;
    upstreamReady = true;
    safeWsSendJson(clientSocket, {
      type: "ready",
      mode: "realtime-control",
      source,
      authenticated: Boolean(config.realtimeControlAuthToken),
    });
    flushPendingClientMessages();
  };

  const handleUpstreamLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed) {
      return;
    }
    let payload;
    try {
      payload = JSON.parse(trimmed);
    } catch (err) {
      closeBoth(4503, `Invalid realtime control response: ${err.message}`);
      return;
    }

    if (authPending) {
      if (payload.type === "auth" && payload.ok) {
        authPending = false;
        if (!startStartupProbe()) {
          closeBoth(4503, "Realtime control socket is not writable");
        }
        return;
      }
      closeBoth(4401, payload.error || "Realtime control authentication failed");
      return;
    }

    if (startupProbePending) {
      startupProbePending = false;
      if (
        (payload.type === "pong" && payload.ok !== false) ||
        (payload.type === "auth" && payload.ok)
      ) {
        markUpstreamReady();
        return;
      }
      closeBoth(
        4503,
        payload.error ||
          payload.message ||
          `Unexpected realtime control response: ${payload.type || "unknown"}`,
      );
      return;
    }

    safeWsSendJson(clientSocket, payload);
  };

  const handleUpstreamData = (chunk) => {
    upstreamBuffer += toBuffer(chunk).toString("utf8");
    let newlineIndex = upstreamBuffer.indexOf("\n");
    while (newlineIndex >= 0) {
      const line = upstreamBuffer.slice(0, newlineIndex);
      upstreamBuffer = upstreamBuffer.slice(newlineIndex + 1);
      handleUpstreamLine(line);
      if (closed) {
        return;
      }
      newlineIndex = upstreamBuffer.indexOf("\n");
    }
    if (upstreamBuffer.length > 1024 * 1024) {
      closeBoth(4503, "Realtime control response is too large");
    }
  };

  clientSocket.on("message", (message, isBinary) => {
    if (closed || isBinary) {
      return;
    }
    let payload;
    try {
      payload = JSON.parse(toBuffer(message).toString("utf8"));
    } catch (err) {
      safeWsSendJson(clientSocket, {
        type: "error",
        message: `Invalid realtime control JSON: ${err.message}`,
      });
      return;
    }

    try {
      payload = prepareRealtimeControlPayload(payload);
    } catch (err) {
      safeWsSendJson(clientSocket, {
        id: payload?.id ?? null,
        type: payload?.type || "error",
        ok: false,
        error: err.message || "Invalid realtime control payload",
      });
      return;
    }

    if (payload && typeof payload === "object" && payload.serverReceiveTimestamp == null) {
      payload.serverReceiveTimestamp = Date.now();
    }

    const normalizedType = normalizeRealtimeControlType(payload?.type || "");
    if (config.realtimeTouchDebugEnabled) {
      logRealtimeInput("ws-recv", payload, {
        upstreamReady: upstreamReady ? 1 : 0,
        normalizedType: normalizedType || "?",
      });
    }

    if (!enqueueClientMessage(payload, normalizedType)) {
      closeBoth(4409, "Realtime control command queue is full");
    }
  });

  clientSocket.on("close", () => {
    closed = true;
    cleanup();
  });

  clientSocket.on("error", () => {
    closed = true;
    cleanup();
  });

  safeWsSendJson(clientSocket, {
    type: "connecting",
    mode: "realtime-control",
    source,
  });

  upstreamSocket = net.createConnection({
    host: config.realtimeControlHost,
    port: config.realtimeControlPort,
  });
  upstreamSocket.setNoDelay(true);
  upstreamSocket.setKeepAlive(true, 1000);
  upstreamSocket.setTimeout(config.realtimeControlConnectTimeoutMs);

  timeoutTimer = setTimeout(() => {
    closeBoth(
      4501,
      `Realtime control connect timed out after ${config.realtimeControlConnectTimeoutMs}ms`,
    );
  }, config.realtimeControlConnectTimeoutMs + 100);

  upstreamSocket.on("connect", () => {
    if (closed) {
      return;
    }
    upstreamSocket.setTimeout(0);
    if (config.realtimeControlAuthToken) {
      authPending = true;
      writeToUpstream({
        type: "auth",
        token: config.realtimeControlAuthToken,
      });
      return;
    }
    if (!startStartupProbe()) {
      closeBoth(4503, "Realtime control socket is not writable");
    }
  });

  upstreamSocket.on("data", handleUpstreamData);
  upstreamSocket.on("drain", () => {
    upstreamWriteBackpressured = false;
    flushPendingClientMessages();
  });
  upstreamSocket.on("timeout", () => {
    closeBoth(
      4501,
      `Realtime control connect timed out after ${config.realtimeControlConnectTimeoutMs}ms`,
    );
  });
  upstreamSocket.on("error", (err) => {
    closeBoth(4501, `Cannot connect realtime control socket ${source}: ${err.message}`);
  });
  upstreamSocket.on("close", () => {
    if (!closed) {
      if (authPending) {
        closeBoth(4503, "Realtime control socket closed during authentication");
        return;
      }
      if (startupProbePending) {
        closeBoth(4503, "Realtime control socket closed before startup probe completed");
        return;
      }
      closeBoth(4503, "Realtime control socket closed");
    }
  });
}

async function handleH264WsClient(clientSocket, reqUrl) {
  const source = resolveH264Source(reqUrl);
  if (!source.ok) {
    closeWsWithError(clientSocket, 4400, source.error);
    return;
  }

  handleLocalBridgeH264WsClient(clientSocket, source);
}

function handleLocalBridgeH264WsClient(clientSocket, source) {
  clientSocket._socket?.setNoDelay?.(true);
  safeWsSendJson(clientSocket, {
    type: "connecting",
    mode: "h264",
    source: source.label,
  });

  localH264Bridge.clients.add(clientSocket);
  clearLocalH264IdleStopTimer();

  clientSocket.on("close", () => {
    localH264Bridge.clients.delete(clientSocket);
    scheduleLocalH264BridgeStopIfIdle();
  });
  clientSocket.on("error", () => {
    localH264Bridge.clients.delete(clientSocket);
    scheduleLocalH264BridgeStopIfIdle();
  });

  ensureLocalH264BridgeRunning()
    .then(() => {
      if (clientSocket.readyState !== WebSocket.OPEN) {
        localH264Bridge.clients.delete(clientSocket);
        scheduleLocalH264BridgeStopIfIdle();
        return;
      }
      safeWsSendJson(clientSocket, {
        type: "ready",
        mode: "h264",
        source: source.label,
      });
      if (localH264Bridge.lastSps) {
        clientSocket.send(localH264Bridge.lastSps, { binary: true }, noop);
      }
      if (localH264Bridge.lastPps) {
        clientSocket.send(localH264Bridge.lastPps, { binary: true }, noop);
      }
    })
    .catch((err) => {
      localH264Bridge.clients.delete(clientSocket);
      closeWsWithError(
        clientSocket,
        4503,
        err.message || "Cannot start local H264 bridge",
      );
    });
}

async function createWebRtcAnswer(whepUrl, offerSdp) {
  let parsedUrl;
  try {
    parsedUrl = new URL(whepUrl);
  } catch (_) {
    const err = new Error(`Invalid WHEP URL: ${whepUrl}`);
    err.status = 400;
    throw err;
  }
  if (!["http:", "https:"].includes(parsedUrl.protocol)) {
    const err = new Error("WHEP URL must start with http:// or https://");
    err.status = 400;
    throw err;
  }

  let response;
  try {
    response = await requestText(parsedUrl.toString(), {
      method: "POST",
      headers: {
        "content-type": "application/sdp",
        accept: "application/sdp",
      },
      body: offerSdp,
      timeoutMs: 20000,
    });
  } catch (err) {
    const e = new Error(
      `Cannot reach WHEP endpoint ${parsedUrl.toString()}: ${err.message}`,
    );
    e.status = 502;
    throw e;
  }

  const responseText = response.text;
  if (!response.ok) {
    const err = new Error(`WHEP endpoint returned HTTP ${response.status}`);
    err.status = 502;
    err.data = { status: response.status, body: responseText.slice(0, 2000) };
    throw err;
  }
  if (!responseText.trim()) {
    const err = new Error("WHEP endpoint returned empty SDP answer");
    err.status = 502;
    throw err;
  }
  return {
    status: response.status,
    sdp: responseText,
    location: response.headers.get("location") || null,
  };
}

function extractJpegFrames(buffer) {
  const frames = [];
  let rest = buffer;

  while (rest.length > 3) {
    const start = rest.indexOf(JPEG_SOI);
    if (start === -1) {
      break;
    }
    const end = rest.indexOf(JPEG_EOI, start + 2);
    if (end === -1) {
      if (start > 0) {
        rest = rest.slice(start);
      }
      break;
    }
    frames.push(rest.slice(start, end + 2));
    rest = rest.slice(end + 2);
  }

  if (rest.length > MAX_MJPEG_BUFFER_BYTES) {
    const start = rest.lastIndexOf(JPEG_SOI);
    rest = start >= 0 ? rest.slice(start) : Buffer.alloc(0);
  }

  return { frames, rest };
}

function resolveMjpegSource(reqUrl) {
  const requested = String(reqUrl.searchParams.get("source") || "").trim();
  if (requested) {
    if (!config.allowDynamicWsSource) {
      return {
        ok: false,
        error:
          "Dynamic source is disabled. Set ALLOW_DYNAMIC_WS_SOURCE=true to enable.",
      };
    }
    const valid = isValidUrlByProtocol(requested, ["http:", "https:"]);
    if (!valid) {
      return { ok: false, error: `Invalid MJPEG source URL: ${requested}` };
    }
    return { ok: true, url: requested, label: "dynamic-source" };
  }
  return { ok: true, url: config.mjpegUrl, label: "configured-mjpeg" };
}

function resolveH264Source(reqUrl) {
  if (!config.localH264FallbackEnabled) {
    return {
      ok: false,
      error:
        "Server H264 binary socket is disabled. Set LOCAL_H264_FALLBACK=true.",
    };
  }

  const requestedDecoder = String(reqUrl.searchParams.get("source") || "h264").toLowerCase();
  return {
    ok: true,
    kind: "local-bridge",
    label: requestedDecoder === "scrcpy"
      ? "local-mjpeg-bridge/scrcpy-decoder"
      : "local-mjpeg-bridge",
  };
}

function isValidUrlByProtocol(value, protocols) {
  try {
    const parsed = new URL(value);
    return protocols.includes(parsed.protocol);
  } catch (_) {
    return false;
  }
}

function isLocalH264DecodeDataError(text) {
  return /No JPEG data found|Invalid data found when processing input|Error submitting packet to decoder/i.test(
    text,
  );
}

function toBuffer(data) {
  if (Buffer.isBuffer(data)) {
    return data;
  }
  if (Array.isArray(data)) {
    const parts = data.map((part) => toBuffer(part));
    return Buffer.concat(parts);
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data);
  }
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  }
  if (typeof data === "string") {
    return Buffer.from(data);
  }
  return Buffer.alloc(0);
}

async function getLocalH264BridgeStatus() {
  const ffmpegAvailable = await probeFfmpegAvailable();
  const mjpegReachable = await isUrlTcpReachable(config.mjpegUrl);
  return {
    enabled: config.localH264FallbackEnabled,
    ffmpegPath: config.ffmpegPath,
    ffmpegAvailable,
    mjpegReachable,
    source: config.mjpegUrl,
    active: Boolean(localH264Bridge.process),
    clients: localH264Bridge.clients.size,
    fps: config.localH264Fps,
    gop: config.localH264Gop,
    maxWidth: config.localH264MaxWidth,
    maxHeight: config.localH264MaxHeight,
    encoder: config.localH264Encoder,
    lastError: localH264Bridge.lastError || null,
  };
}

async function getLocalH264Capability() {
  if (!config.localH264FallbackEnabled) {
    return {
      enabled: false,
      reachable: false,
      reasonIfUnavailable: "LOCAL_H264_FALLBACK is disabled",
      warningIfUnreachable: null,
    };
  }
  const ffmpegAvailable = await probeFfmpegAvailable();
  if (!ffmpegAvailable) {
    return {
      enabled: false,
      reachable: false,
      reasonIfUnavailable: `Cannot run ffmpeg (${config.ffmpegPath}). Install ffmpeg or set FFMPEG_PATH.`,
      warningIfUnreachable: null,
    };
  }
  const mjpegReachable = await isUrlTcpReachable(config.mjpegUrl);
  return {
    enabled: true,
    reachable: mjpegReachable,
    reasonIfUnavailable: null,
    warningIfUnreachable: mjpegReachable
      ? null
      : `MJPEG source ${config.mjpegUrl} is not reachable right now`,
  };
}

async function ensureLocalH264BridgeRunning() {
  if (!config.localH264FallbackEnabled) {
    throw new Error(
      "Local H264 fallback is disabled (LOCAL_H264_FALLBACK=false)",
    );
  }
  const ffmpegAvailable = await probeFfmpegAvailable();
  if (!ffmpegAvailable) {
    throw new Error(
      `Cannot run ffmpeg at "${config.ffmpegPath}". Install ffmpeg or set FFMPEG_PATH.`,
    );
  }
  clearLocalH264IdleStopTimer();
  if (localH264Bridge.process) {
    return;
  }
  startLocalH264BridgeProcess();
}

function startLocalH264BridgeProcess() {
  if (localH264Bridge.process || localH264Bridge.shuttingDown) {
    return;
  }
  clearTimeout(localH264Bridge.restartTimer);
  localH264Bridge.restartTimer = null;
  localH264Bridge.restarting = false;
  localH264Bridge.carry = Buffer.alloc(0);
  localH264Bridge.lastSps = null;
  localH264Bridge.lastPps = null;
  localH264Bridge.pendingNals = [];
  localH264Bridge.pendingHasVcl = false;
  localH264Bridge.decodeErrorStreak = 0;
  localH264Bridge.lastDecodeErrorAt = 0;

  const args = buildLocalH264FfmpegArgs();
  console.log(`[h264-local] starting: ${config.ffmpegPath} ${args.join(" ")}`);
  const proc = spawn(config.ffmpegPath, args, {
    stdio: ["ignore", "pipe", "pipe"],
  });
  localH264Bridge.process = proc;

  proc.stdout.on("data", onLocalH264BridgeData);
  proc.stderr.on("data", (chunk) => {
    const text = String(chunk || "").trim();
    if (!text) {
      return;
    }
    localH264Bridge.lastError = text.slice(-2000);
    if (isLocalH264DecodeDataError(text)) {
      const now = Date.now();
      if (
        now - localH264Bridge.lastDecodeErrorAt >
        LOCAL_H264_DECODE_ERROR_WINDOW_MS
      ) {
        localH264Bridge.decodeErrorStreak = 0;
      }
      localH264Bridge.lastDecodeErrorAt = now;
      localH264Bridge.decodeErrorStreak += 1;
      if (
        localH264Bridge.decodeErrorStreak >=
          LOCAL_H264_DECODE_ERROR_RESTART_THRESHOLD &&
        localH264Bridge.clients.size > 0
      ) {
        localH264Bridge.decodeErrorStreak = 0;
        broadcastLocalH264Control({
          type: "log",
          level: "warn",
          message:
            "Local MJPEG->H264 bridge hit repeated decode errors; restarting bridge.",
        });
        scheduleLocalH264BridgeRestart();
      }
    }
  });

  proc.on("exit", (code, signal) => {
    if (localH264Bridge.process === proc) {
      localH264Bridge.process = null;
    }
    localH264Bridge.carry = Buffer.alloc(0);
    localH264Bridge.pendingNals = [];
    localH264Bridge.pendingHasVcl = false;
    const message = `Local MJPEG->H264 bridge exited (code=${code ?? "null"}, signal=${signal ?? "null"})`;
    if (!localH264Bridge.shuttingDown && localH264Bridge.clients.size > 0) {
      broadcastLocalH264Control({
        type: "error",
        message: `${message}. Retrying...`,
      });
      scheduleLocalH264BridgeRestart();
    }
  });

  proc.on("error", (err) => {
    localH264Bridge.lastError = err.message || String(err);
    if (localH264Bridge.clients.size > 0) {
      closeAllLocalH264ClientsWithError(
        `Cannot start local H264 bridge: ${localH264Bridge.lastError}`,
      );
    }
  });
}

function stopLocalH264BridgeProcess(reason) {
  clearTimeout(localH264Bridge.restartTimer);
  localH264Bridge.restartTimer = null;
  localH264Bridge.restarting = false;
  localH264Bridge.carry = Buffer.alloc(0);
  localH264Bridge.lastSps = null;
  localH264Bridge.lastPps = null;
  localH264Bridge.pendingNals = [];
  localH264Bridge.pendingHasVcl = false;
  localH264Bridge.decodeErrorStreak = 0;
  localH264Bridge.lastDecodeErrorAt = 0;
  if (!localH264Bridge.process) {
    return;
  }
  try {
    localH264Bridge.process.kill("SIGTERM");
  } catch (_) {
    // no-op
  }
  if (reason) {
    console.log(`[h264-local] stopping: ${reason}`);
  }
}

function scheduleLocalH264BridgeRestart() {
  if (localH264Bridge.shuttingDown || localH264Bridge.restarting) {
    return;
  }
  localH264Bridge.restarting = true;
  clearTimeout(localH264Bridge.restartTimer);
  localH264Bridge.restartTimer = setTimeout(() => {
    localH264Bridge.restartTimer = null;
    localH264Bridge.restarting = false;
    if (localH264Bridge.shuttingDown || localH264Bridge.clients.size === 0) {
      return;
    }
    ensureLocalH264BridgeRunning().catch((err) => {
      closeAllLocalH264ClientsWithError(
        err.message || "Cannot restart local H264 bridge",
      );
    });
  }, 1200);
}

function clearLocalH264IdleStopTimer() {
  if (localH264Bridge.idleStopTimer) {
    clearTimeout(localH264Bridge.idleStopTimer);
    localH264Bridge.idleStopTimer = null;
  }
}

function scheduleLocalH264BridgeStopIfIdle() {
  if (
    localH264Bridge.shuttingDown ||
    localH264Bridge.clients.size > 0 ||
    !localH264Bridge.process
  ) {
    return;
  }
  clearLocalH264IdleStopTimer();
  localH264Bridge.idleStopTimer = setTimeout(() => {
    localH264Bridge.idleStopTimer = null;
    if (localH264Bridge.clients.size === 0 && localH264Bridge.process) {
      stopLocalH264BridgeProcess("idle");
    }
  }, LOCAL_H264_BRIDGE_IDLE_STOP_MS);
}

function closeAllLocalH264ClientsWithError(message) {
  for (const client of localH264Bridge.clients) {
    closeWsWithError(client, 4503, message);
  }
}

function broadcastLocalH264Control(payload) {
  for (const client of localH264Bridge.clients) {
    safeWsSendJson(client, payload);
  }
}

function onLocalH264BridgeData(chunk) {
  const data = toBuffer(chunk);
  if (!data.length) {
    return;
  }
  localH264Bridge.decodeErrorStreak = 0;
  localH264Bridge.carry = Buffer.concat([localH264Bridge.carry, data]);
  processLocalH264Carry();
}

function processLocalH264Carry() {
  if (localH264Bridge.carry.length < 5) {
    return;
  }

  let carry = localH264Bridge.carry;
  let first = findH264StartCode(carry, 0);
  if (!first) {
    if (carry.length > MAX_H264_CARRY_BYTES) {
      carry = carry.subarray(carry.length - 4);
    }
    localH264Bridge.carry = carry;
    return;
  }

  if (first.index > 0) {
    carry = carry.subarray(first.index);
    first = { index: 0, length: first.length };
  }

  const starts = [first];
  let cursor = first.index + first.length;
  while (true) {
    const next = findH264StartCode(carry, cursor);
    if (!next) {
      break;
    }
    starts.push(next);
    cursor = next.index + next.length;
  }

  if (starts.length < 2) {
    if (carry.length > MAX_H264_CARRY_BYTES) {
      carry = carry.subarray(starts[0].index);
    }
    localH264Bridge.carry = carry;
    return;
  }

  for (let i = 0; i < starts.length - 1; i += 1) {
    const start = starts[i];
    const next = starts[i + 1];
    const nal = carry.subarray(start.index + start.length, next.index);
    onLocalH264Nal(nal);
  }

  carry = carry.subarray(starts[starts.length - 1].index);
  if (carry.length > MAX_H264_CARRY_BYTES) {
    carry = carry.subarray(carry.length - 4);
  }
  localH264Bridge.carry = carry;
}

function onLocalH264Nal(nal) {
  if (!nal || nal.length < 1) {
    return;
  }
  const nalType = nal[0] & 0x1f;
  const isVcl = nalType === 1 || nalType === 5;
  const shouldFlushByAud = nalType === 9 && localH264Bridge.pendingHasVcl;
  const shouldFlushByFirstSlice =
    isVcl && localH264Bridge.pendingHasVcl && isFirstSliceNalBuffer(nal);
  const shouldFlushByConfig =
    !isVcl && localH264Bridge.pendingHasVcl && (nalType === 7 || nalType === 8);

  if (shouldFlushByAud || shouldFlushByFirstSlice || shouldFlushByConfig) {
    flushLocalH264AccessUnit();
  }

  localH264Bridge.pendingNals.push(Buffer.from(nal));
  if (isVcl) {
    localH264Bridge.pendingHasVcl = true;
  }
  if (nalType === 7) {
    localH264Bridge.lastSps = withStartCode(nal);
  } else if (nalType === 8) {
    localH264Bridge.lastPps = withStartCode(nal);
  }
}

function flushLocalH264AccessUnit() {
  if (
    !localH264Bridge.pendingHasVcl ||
    localH264Bridge.pendingNals.length === 0
  ) {
    localH264Bridge.pendingNals = [];
    localH264Bridge.pendingHasVcl = false;
    return;
  }
  const accessUnit = buildAnnexBAccessUnit(localH264Bridge.pendingNals);
  localH264Bridge.pendingNals = [];
  localH264Bridge.pendingHasVcl = false;
  if (!accessUnit || accessUnit.length === 0) {
    return;
  }
  for (const client of localH264Bridge.clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(accessUnit, { binary: true }, noop);
    }
  }
}

function withStartCode(nal) {
  if (!nal || nal.length === 0) {
    return Buffer.alloc(0);
  }
  const out = Buffer.allocUnsafe(4 + nal.length);
  out[0] = 0x00;
  out[1] = 0x00;
  out[2] = 0x00;
  out[3] = 0x01;
  nal.copy(out, 4);
  return out;
}

function buildAnnexBAccessUnit(nals) {
  if (!Array.isArray(nals) || nals.length === 0) {
    return Buffer.alloc(0);
  }
  let totalLength = 0;
  for (const nal of nals) {
    if (nal && nal.length > 0) {
      totalLength += 4 + nal.length;
    }
  }
  if (!totalLength) {
    return Buffer.alloc(0);
  }
  const out = Buffer.allocUnsafe(totalLength);
  let offset = 0;
  for (const nal of nals) {
    if (!nal || nal.length === 0) {
      continue;
    }
    out[offset++] = 0x00;
    out[offset++] = 0x00;
    out[offset++] = 0x00;
    out[offset++] = 0x01;
    nal.copy(out, offset);
    offset += nal.length;
  }
  return out;
}

function isFirstSliceNalBuffer(nal) {
  const nalType = nalTypeOfBuffer(nal);
  if (nalType !== 1 && nalType !== 5) {
    return false;
  }
  if (!nal || nal.length < 2) {
    return false;
  }
  const rbsp = removeEmulationPreventionBytesBuffer(nal.subarray(1));
  const ue = readUnsignedExpGolombBuffer(rbsp, 0);
  return Boolean(ue && ue.value === 0);
}

function nalTypeOfBuffer(nal) {
  if (!nal || nal.length === 0) {
    return 0;
  }
  return nal[0] & 0x1f;
}

function removeEmulationPreventionBytesBuffer(data) {
  const out = [];
  for (let i = 0; i < data.length; i += 1) {
    if (
      i >= 2 &&
      data[i] === 0x03 &&
      data[i - 1] === 0x00 &&
      data[i - 2] === 0x00
    ) {
      continue;
    }
    out.push(data[i]);
  }
  return Buffer.from(out);
}

function readUnsignedExpGolombBuffer(data, bitOffset) {
  const maxBits = data.length * 8;
  if (bitOffset >= maxBits) {
    return null;
  }
  let leadingZeroBits = 0;
  while (
    bitOffset + leadingZeroBits < maxBits &&
    readBitBuffer(data, bitOffset + leadingZeroBits) === 0
  ) {
    leadingZeroBits += 1;
    if (leadingZeroBits > 31) {
      return null;
    }
  }
  if (bitOffset + leadingZeroBits >= maxBits) {
    return null;
  }
  let value = 1;
  for (let i = 0; i < leadingZeroBits; i += 1) {
    const bit = readBitBuffer(data, bitOffset + leadingZeroBits + 1 + i);
    value = (value << 1) | bit;
  }
  return {
    value: value - 1,
    bits: leadingZeroBits * 2 + 1,
  };
}

function readBitBuffer(data, bitIndex) {
  const byteIndex = bitIndex >> 3;
  if (byteIndex < 0 || byteIndex >= data.length) {
    return 0;
  }
  const shift = 7 - (bitIndex & 7);
  return (data[byteIndex] >> shift) & 1;
}

function findH264StartCode(buffer, fromIndex) {
  for (let i = Math.max(0, fromIndex); i < buffer.length - 3; i += 1) {
    if (buffer[i] !== 0x00 || buffer[i + 1] !== 0x00) {
      continue;
    }
    if (buffer[i + 2] === 0x01) {
      return { index: i, length: 3 };
    }
    if (buffer[i + 2] === 0x00 && buffer[i + 3] === 0x01) {
      return { index: i, length: 4 };
    }
  }
  return null;
}

function buildLocalH264FfmpegArgs() {
  const fps = String(config.localH264Fps);
  const gop = String(config.localH264Gop);
  // Crop a thin right/bottom edge before scaling to remove white border artifacts on low WDA scaling.
  const preCropFilter = "crop=w=iw-2*gte(iw\\,4):h=ih-2*gte(ih\\,4):x=0:y=0";
  const scaleFilter = `${preCropFilter},scale=w=${config.localH264MaxWidth}:h=${config.localH264MaxHeight}:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1`;
  const args = [
    "-hide_banner",
    "-loglevel",
    "warning",
    "-fflags",
    "nobuffer",
    "-flags",
    "low_delay",
    "-f",
    "mpjpeg",
    "-i",
    config.mjpegUrl,
    "-an",
    "-c:v",
    config.localH264Encoder,
    "-preset",
    "ultrafast",
    "-tune",
    "zerolatency",
    "-pix_fmt",
    "yuv420p",
    "-vf",
    scaleFilter,
    "-profile:v",
    "baseline",
    "-level",
    "3.1",
    "-bf",
    "0",
    "-r",
    fps,
    "-g",
    gop,
    "-keyint_min",
    gop,
  ];
  if (String(config.localH264Encoder).toLowerCase() === "libx264") {
    args.push(
      "-x264-params",
      `keyint=${gop}:min-keyint=${gop}:scenecut=0:repeat-headers=1:aud=1`,
    );
  }
  if (String(config.localH264Encoder).toLowerCase().includes("264")) {
    args.push("-bsf:v", "h264_metadata=aud=insert");
  }
  args.push("-f", "h264", "pipe:1");
  return args;
}

function probeFfmpegAvailable() {
  if (localH264Bridge.ffmpegAvailable !== null) {
    return Promise.resolve(localH264Bridge.ffmpegAvailable);
  }
  if (localH264Bridge.ffmpegProbePromise) {
    return localH264Bridge.ffmpegProbePromise;
  }

  localH264Bridge.ffmpegProbePromise = new Promise((resolve) => {
    let settled = false;
    const proc = spawn(config.ffmpegPath, ["-version"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const finish = (ok) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      localH264Bridge.ffmpegAvailable = Boolean(ok);
      localH264Bridge.ffmpegProbePromise = null;
      resolve(Boolean(ok));
    };
    const timer = setTimeout(() => {
      try {
        proc.kill("SIGTERM");
      } catch (_) {
        // no-op
      }
      finish(false);
    }, 2200);

    proc.once("error", () => finish(false));
    proc.once("exit", (code) => finish(code === 0));
  });

  return localH264Bridge.ffmpegProbePromise;
}

function handleShutdownSignal(signal) {
  localH264Bridge.shuttingDown = true;
  clearLocalH264IdleStopTimer();
  for (const client of localH264Bridge.clients) {
    try {
      client.close(1001, "server shutdown");
    } catch (_) {
      // no-op
    }
  }
  stopLocalH264BridgeProcess(signal || "shutdown");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1200);
}

function closeWsWithError(ws, code, message) {
  safeWsSendJson(ws, { type: "error", message });
  if (
    ws.readyState === WebSocket.OPEN ||
    ws.readyState === WebSocket.CONNECTING
  ) {
    ws.close(code, trimCloseReason(message));
  }
}

function safeWsSendJson(ws, payload) {
  if (ws.readyState !== WebSocket.OPEN) {
    return;
  }
  try {
    ws.send(JSON.stringify(payload), { binary: false }, noop);
  } catch (_) {
    // no-op
  }
}

function trimCloseReason(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  const bytes = Buffer.from(raw, "utf8");
  if (bytes.length <= 123) {
    return raw;
  }
  return bytes.subarray(0, 123).toString("utf8");
}

async function buildViewModes() {
  const localH264 = await getLocalH264Capability();
  const hasH264Pipeline = localH264.enabled;
  const h264Reachable = localH264.reachable;

  const hasWhepConfig = Boolean(config.webrtcWhepUrl);
  const whepReachable = hasWhepConfig
    ? await isUrlTcpReachable(config.webrtcWhepUrl)
    : false;

  const h264Reason =
    localH264.reasonIfUnavailable || "Enable LOCAL_H264_FALLBACK and install ffmpeg";
  const whepReason = "Set WEBRTC_WHEP_URL";
  const h264Warning = localH264.warningIfUnreachable;
  const whepWarning =
    hasWhepConfig && !whepReachable
      ? "Configured WHEP endpoint is not reachable right now"
      : null;

  return {
    ok: true,
    endpoints: {
      mjpegHttp: "/stream.mjpeg",
      mjpegWs: "/ws/mjpeg",
      h264Ws: "/ws/h264",
      realtimeControlWs: "/ws/realtime-control",
      webrtcOffer: "/api/webrtc-offer",
    },
    upstream: {
      webrtcWhepUrl: config.webrtcWhepUrl || null,
      allowDynamicWsSource: config.allowDynamicWsSource,
      localH264Fallback: {
        enabled: localH264.enabled,
        source: config.mjpegUrl,
        reachable: localH264.reachable,
        warningIfUnreachable: localH264.warningIfUnreachable,
      },
    },
    modes: [
      {
        id: "mjpeg-wda",
        label: "MJPEG WDA",
        transport: "http",
        enabled: true,
      },
      {
        id: "mjpeg-binary",
        label: "MJPEG Binary Socket",
        transport: "ws",
        enabled: true,
      },
      {
        id: "mjpeg-canvas",
        label: "MJPEG Canvas Socket",
        transport: "ws-canvas",
        enabled: true,
      },
      {
        id: "broadway",
        label: "Broadway",
        transport: "ws-h264",
        enabled: hasH264Pipeline,
        reachable: h264Reachable,
        reasonIfUnavailable: hasH264Pipeline ? null : h264Reason,
        warningIfUnreachable: h264Warning,
        sourceKind: "local-mjpeg-bridge",
      },
      {
        id: "h264-live-player",
        label: "h264-live-player",
        transport: "ws-h264",
        enabled: hasH264Pipeline,
        reachable: h264Reachable,
        reasonIfUnavailable: hasH264Pipeline ? null : h264Reason,
        warningIfUnreachable: h264Warning,
        sourceKind: "local-mjpeg-bridge",
      },
      {
        id: "scrcpy",
        label: "Genymobile/scrcpy",
        transport: "ws-h264",
        enabled: hasH264Pipeline,
        reachable: h264Reachable,
        reasonIfUnavailable: hasH264Pipeline ? null : h264Reason,
        warningIfUnreachable: h264Warning,
        sourceKind: "local-mjpeg-bridge",
      },
      {
        id: "tinyh264",
        label: "tinyh264",
        transport: "ws-h264",
        enabled: hasH264Pipeline,
        reachable: h264Reachable,
        reasonIfUnavailable: hasH264Pipeline ? null : h264Reason,
        warningIfUnreachable: h264Warning,
        sourceKind: "local-mjpeg-bridge",
      },
      {
        id: "webcodecs",
        label: "WebCodecs",
        transport: "ws-h264",
        enabled: hasH264Pipeline,
        reachable: h264Reachable,
        reasonIfUnavailable: hasH264Pipeline ? null : h264Reason,
        warningIfUnreachable: h264Warning,
        sourceKind: "local-mjpeg-bridge",
      },
      {
        id: "webrtc-h264",
        label: "H.264/WebRTC",
        transport: "webrtc",
        enabled: hasWhepConfig,
        reachable: whepReachable,
        reasonIfUnavailable: hasWhepConfig ? null : whepReason,
        warningIfUnreachable: whepWarning,
      },
    ],
  };
}

async function buildControlModes() {
  const realtimeUrl = `tcp://${config.realtimeControlHost}:${config.realtimeControlPort}`;
  const realtimeProbe = await probeRealtimeControl(700);
  const realtimeReachable = realtimeProbe.reachable;
  return {
    ok: true,
    defaultMode: realtimeReachable ? "realtime" : "http-point-array",
    endpoints: {
      realtimeControlWs: "/ws/realtime-control",
    },
    upstream: {
      realtimeControlUrl: realtimeUrl,
      realtimeReachable,
      activeRealtimeClients: state.realtimeControlConnections,
      authTokenConfigured: Boolean(config.realtimeControlAuthToken),
      realtimeProbe,
    },
    modes: [
      {
        id: "realtime",
        label: "Realtime socket",
        transport: "ws-tcp-ndjson",
        enabled: true,
        reachable: realtimeReachable,
        warningIfUnreachable: realtimeReachable
          ? null
          : realtimeProbe.warning ||
            `WDA realtime socket ${realtimeUrl} is not reachable right now`,
      },
      {
        id: "http-point-array",
        label: "HTTP PointArray",
        transport: "http-point-array",
        enabled: true,
        reachable: true,
      },
      {
        id: "http-swipe",
        label: "HTTP Swipe",
        transport: "http-swipe",
        enabled: true,
        reachable: true,
      },
    ],
  };
}

function prepareRealtimeControlPayload(rawPayload) {
  if (!rawPayload || typeof rawPayload !== "object" || Array.isArray(rawPayload)) {
    const err = new Error("Realtime control payload must be an object");
    err.status = 400;
    throw err;
  }

  const payload = { ...rawPayload };
  const type =
    typeof payload.type === "string" && payload.type.trim()
      ? payload.type.trim()
      : "pointArray";
  payload.type = normalizeRealtimeControlType(type);

  const normalizedType = payload.type.toLowerCase();
  if (normalizedType === "down" || normalizedType === "move") {
    return {
      ...payload,
      ...normalizeTouchPayload(payload, { requirePoint: true }),
      type: payload.type,
    };
  }

  if (normalizedType === "up" || normalizedType === "cancel") {
    return {
      ...payload,
      ...normalizeTouchPayload(payload, { requirePoint: false }),
      type: payload.type,
    };
  }

  if (normalizedType === "hidprobe") {
    return {
      ...payload,
      ...normalizeTouchPayload(payload, { requirePoint: false }),
      type: payload.type,
    };
  }

  if (normalizedType === "pointarray" || normalizedType === "gesture") {
    const pointArray = normalizePointArray(
      payload.pointArray || payload.points || payload.path || payload.data,
    );
    payload.pointArray = pointArray;
    signPointArrayPayloadIfNeeded(payload, pointArray);
    return payload;
  }

  if (normalizedType === "swipe") {
    const rawPoints = payload.pointArray || payload.points;
    if (Array.isArray(rawPoints)) {
      const pointArray = normalizePointArray(rawPoints);
      payload.pointArray = pointArray;
      signPointArrayPayloadIfNeeded(payload, pointArray);
    }
    return payload;
  }

  return payload;
}

function normalizeRealtimeControlType(type) {
  const normalized = String(type || "").trim().toLowerCase();
  const compact = normalized.replace(/[-_]/g, "");
  if (
    compact === "touchdown" ||
    compact === "pointerdown" ||
    compact === "touch1down" ||
    compact === "touchbegin" ||
    compact === "begin" ||
    compact === "down"
  ) {
    return "down";
  }
  if (
    compact === "touchmove" ||
    compact === "pointermove" ||
    compact === "touch1move" ||
    compact === "move"
  ) {
    return "move";
  }
  if (
    compact === "touchup" ||
    compact === "pointerup" ||
    compact === "touch1up" ||
    compact === "touchend" ||
    compact === "end" ||
    compact === "up"
  ) {
    return "up";
  }
  if (
    compact === "touchcancel" ||
    compact === "pointercancel" ||
    compact === "cancel"
  ) {
    return "cancel";
  }
  if (compact === "hidprobe" || compact === "hidstatus") {
    return "hidProbe";
  }
  if (compact === "pointarray") {
    return "pointArray";
  }
  return normalized;
}

function signPointArrayPayloadIfNeeded(payload, pointArray) {
  const incomingSt = typeof payload.st === "string" ? payload.st.trim() : "";
  if (incomingSt || !config.pointArraySecret) {
    if (incomingSt) {
      payload.st = incomingSt;
    }
    return;
  }
  payload.st = buildPointArraySt(pointArray, config.pointArraySecret);
}

function isUrlTcpReachable(urlString, timeoutMs = 900) {
  let parsed;
  try {
    parsed = new URL(urlString);
  } catch (_) {
    return Promise.resolve(false);
  }

  const protocol = parsed.protocol;
  const port = parsed.port
    ? Number(parsed.port)
    : protocol === "https:" || protocol === "wss:"
      ? 443
      : 80;
  const host = parsed.hostname;
  if (!host || !Number.isFinite(port) || port <= 0) {
    return Promise.resolve(false);
  }

  return new Promise((resolve) => {
    let settled = false;
    const socket = net.createConnection({ host, port });
    const finalize = (ok) => {
      if (settled) {
        return;
      }
      settled = true;
      socket.destroy();
      resolve(Boolean(ok));
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finalize(true));
    socket.once("timeout", () => finalize(false));
    socket.once("error", () => finalize(false));
  });
}

function probeRealtimeControl(timeoutMs = 900) {
  const host = config.realtimeControlHost;
  const port = config.realtimeControlPort;
  const source = `tcp://${host}:${port}`;
  const authToken = config.realtimeControlAuthToken;

  if (!host || !Number.isFinite(port) || port <= 0) {
    return Promise.resolve({
      reachable: false,
      warning: `Invalid realtime control endpoint: ${source}`,
    });
  }

  return new Promise((resolve) => {
    let settled = false;
    let buffer = "";
    let authPending = false;
    let probePending = false;
    let socket = null;

    const finalize = (reachable, warning) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (socket) {
        socket.destroy();
      }
      resolve({
        reachable: Boolean(reachable),
        warning: warning || null,
      });
    };

    const sendLine = (payload) => {
      if (!socket || !socket.writable) {
        return false;
      }
      socket.write(`${JSON.stringify(payload)}\n`, noop);
      return true;
    };

    const sendProbe = () => {
      probePending = true;
      if (!sendLine({type: "ping", id: "realtime-probe"})) {
        finalize(false, "Realtime control probe could not be sent");
      }
    };

    const handleLine = (line) => {
      const trimmed = line.trim();
      if (!trimmed) {
        return;
      }

      let payload;
      try {
        payload = JSON.parse(trimmed);
      } catch (err) {
        finalize(false, `Invalid realtime control probe response: ${err.message}`);
        return;
      }

      if (authPending) {
        if (payload.type === "auth" && payload.ok) {
          authPending = false;
          sendProbe();
          return;
        }
        finalize(false, payload.error || "Realtime control authentication failed");
        return;
      }

      if (probePending) {
        if ((payload.type === "pong" && payload.ok !== false) || payload.ok === true) {
          finalize(true);
          return;
        }
        if (payload.type === "auth" && payload.ok === false) {
          finalize(false, payload.error || "WDA auth token is required");
          return;
        }
        finalize(
          false,
          payload.error ||
            payload.message ||
            `Unexpected realtime control probe response: ${payload.type || "unknown"}`,
        );
        return;
      }

      finalize(false, `Unexpected realtime control probe response: ${trimmed.slice(0, 120)}`);
    };

    const timer = setTimeout(() => {
      finalize(false, `Realtime control probe timed out after ${timeoutMs}ms`);
    }, timeoutMs + 50);

    socket = net.createConnection({host, port});
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 1000);
    socket.setTimeout(timeoutMs);

    socket.once("connect", () => {
      if (settled) {
        return;
      }
      socket.setTimeout(0);
      if (authToken) {
        authPending = true;
        if (!sendLine({type: "auth", token: authToken})) {
          finalize(false, "Realtime control auth could not be sent");
        }
        return;
      }
      sendProbe();
    });

    socket.on("data", (chunk) => {
      buffer += toBuffer(chunk).toString("utf8");
      let newlineIndex = buffer.indexOf("\n");
      while (newlineIndex >= 0 && !settled) {
        const line = buffer.slice(0, newlineIndex);
        buffer = buffer.slice(newlineIndex + 1);
        handleLine(line);
        newlineIndex = buffer.indexOf("\n");
      }
    });
    socket.once("timeout", () => {
      finalize(false, `Realtime control probe timed out after ${timeoutMs}ms`);
    });
    socket.once("error", (err) => {
      finalize(false, `Cannot connect realtime control socket ${source}: ${err.message}`);
    });
    socket.once("close", () => {
      if (!settled) {
        finalize(false, "Realtime control socket closed before probe completed");
      }
    });
  });
}

function getSetupActionList() {
  return Array.from(setupActions.entries()).map(([id, action]) => ({
    id,
    label: action.label,
    requiresUdid: Boolean(action.requiresUdid),
    timeoutMs: action.timeoutMs || SETUP_COMMAND_TIMEOUT_MS,
    command: [config.goIosBin, ...action.args].join(" "),
  }));
}

function sanitizeOptionalUdid(value) {
  const raw = typeof value === "string" ? value.trim() : "";
  if (!raw) {
    return "";
  }
  if (!/^[a-zA-Z0-9-]+$/.test(raw)) {
    const err = new Error("UDID contains unsupported characters");
    err.status = 400;
    throw err;
  }
  return raw;
}

function parseGoIosDeviceList(stdout) {
  if (typeof stdout !== "string" || !stdout.trim()) {
    return [];
  }
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (_) {
    return [];
  }
  const rawDevices = Array.isArray(parsed?.deviceList)
    ? parsed.deviceList
    : Array.isArray(parsed)
      ? parsed
      : [];
  return rawDevices.map((device) => ({
    udid: device.Udid || device.UniqueDeviceID || device.udid || "",
    name: device.DeviceName || device.Name || "",
    productType: device.ProductType || "",
    productVersion: device.ProductVersion || "",
    connectionType: device.ConnectionType || "",
  })).filter((device) => device.udid);
}

function runGoIosCommand(args, options = {}) {
  const timeoutMs = Math.max(
    1000,
    Math.min(
      10 * 60 * 1000,
      Number(options.timeoutMs) || SETUP_COMMAND_TIMEOUT_MS,
    ),
  );
  const command = [config.goIosBin, ...args].join(" ");

  return new Promise((resolve) => {
    let settled = false;
    let timedOut = false;
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let stdoutTruncated = false;
    let stderrTruncated = false;
    let timer = null;

    const finish = (payload) => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer) {
        clearTimeout(timer);
      }
      resolve({
        command,
        args,
        timedOut,
        stdout: stdout.toString("utf8"),
        stderr: stderr.toString("utf8"),
        stdoutTruncated,
        stderrTruncated,
        ...payload,
      });
    };

    let child;
    try {
      child = spawn(config.goIosBin, args, {
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      finish({
        ok: false,
        code: null,
        signal: null,
        error: err.message || String(err),
      });
      return;
    }

    const appendLimited = (target, chunk) => {
      const current = target === "stdout" ? stdout : stderr;
      const nextChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const available = Math.max(0, SETUP_OUTPUT_LIMIT_BYTES - current.length);
      let next = current;
      let truncated = target === "stdout" ? stdoutTruncated : stderrTruncated;
      if (available > 0) {
        next = Buffer.concat([current, nextChunk.subarray(0, available)]);
      }
      if (nextChunk.length > available) {
        truncated = true;
      }
      if (target === "stdout") {
        stdout = next;
        stdoutTruncated = truncated;
      } else {
        stderr = next;
        stderrTruncated = truncated;
      }
    };

    timer = setTimeout(() => {
      timedOut = true;
      try {
        child.kill("SIGTERM");
      } catch (_) {
        // Ignore: process may already be gone.
      }
      setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch (_) {
          // Ignore: best effort cleanup only.
        }
      }, 1200);
    }, timeoutMs);

    child.stdout.on("data", (chunk) => appendLimited("stdout", chunk));
    child.stderr.on("data", (chunk) => appendLimited("stderr", chunk));
    child.once("error", (err) => {
      finish({
        ok: false,
        code: null,
        signal: null,
        error: err.message || String(err),
      });
    });
    child.once("close", (code, signal) => {
      finish({
        ok: code === 0 && !timedOut,
        code,
        signal,
        error: code === 0 && !timedOut ? null : `go-ios exited with ${signal || code}`,
      });
    });
  });
}

function resolvePublicFilePath(pathname) {
  if (!pathname || pathname === "/") {
    return null;
  }
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch (_) {
    return null;
  }
  const normalized = path.normalize(decoded).replace(/^([/\\])+/, "");
  if (!normalized || normalized.startsWith("..")) {
    return null;
  }
  const resolved = path.resolve(publicDir, normalized);
  if (!resolved.startsWith(publicDir)) {
    return null;
  }
  return resolved;
}

function getContentType(filePath) {
  return (
    contentTypes.get(path.extname(filePath).toLowerCase()) ||
    "application/octet-stream"
  );
}

function serveFile(res, filePath, contentType) {
  fs.readFile(filePath, (err, data) => {
    if (err) {
      json(res, 404, { ok: false, error: "File not found" });
      return;
    }
    res.writeHead(200, {
      "content-type": contentType || getContentType(filePath),
      "cache-control": "no-store",
    });
    res.end(data);
  });
}

function isAllowedOrigin(req) {
  if (!config.allowedOrigin) {
    return true;
  }
  const origin = req.headers.origin;
  return !origin || origin === config.allowedOrigin;
}

function isRequestAuthorized(req, reqUrl) {
  if (!config.authToken || !isProtectedPath(reqUrl.pathname)) {
    return true;
  }
  const token = extractRequestToken(req, reqUrl);
  return timingSafeStringEqual(token, config.authToken);
}

function isProtectedPath(pathname) {
  return (
    pathname === "/health" ||
    pathname === "/stream.mjpeg" ||
    pathname.startsWith("/api/") ||
    pathname.startsWith("/ws/")
  );
}

function extractRequestToken(req, reqUrl) {
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
    reqUrl.searchParams.get("auth") || reqUrl.searchParams.get("token") || "",
  ).trim();
}

function timingSafeStringEqual(a, b) {
  const left = Buffer.from(String(a || ""), "utf8");
  const right = Buffer.from(String(b || ""), "utf8");
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function unauthorized(res) {
  res.setHeader("WWW-Authenticate", 'Bearer realm="ios-wda-stream"');
  return json(res, 401, { ok: false, error: "Unauthorized" });
}

function json(res, statusCode, payload) {
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(payload, null, 2));
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (!text) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    const e = new Error(`Invalid JSON body: ${err.message}`);
    e.status = 400;
    throw e;
  }
}

function parseMaybeJson(text) {
  if (typeof text !== "string" || !text.trim()) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch (_) {
    return { raw: text };
  }
}

function extractSessionId(data) {
  return data?.sessionId || data?.value?.sessionId || null;
}

function unwrapValue(data) {
  return data && Object.prototype.hasOwnProperty.call(data, "value")
    ? data.value
    : data;
}

function isWdaError(data) {
  return Boolean(data?.value?.error || data?.error);
}

function isInvalidSession(data) {
  const error = data?.value?.error || data?.error || "";
  const message = `${error} ${extractWdaMessage(data) || ""}`.toLowerCase();
  return (
    message.includes("invalid session") || message.includes("no active session")
  );
}

function extractWdaMessage(data) {
  return (
    data?.value?.message ||
    data?.message ||
    data?.value?.error ||
    data?.error ||
    data?.raw ||
    null
  );
}

function networkHintForCode(code) {
  if (!code) {
    return null;
  }
  if (
    ["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "ETIMEDOUT"].includes(code)
  ) {
    return "Check WDA tunnel and forward 8000 8000 before calling SID APIs (/api/connect or /api/session-id)";
  }
  if (code === "ECONNRESET") {
    return "WDA connection was reset; restart tunnel, runwda, and forward 8000 8000";
  }
  return null;
}

function sanitizeSettings(body) {
  const settings = {};
  if (body.mjpegServerFramerate !== undefined) {
    settings.mjpegServerFramerate = requireIntInRange(
      body.mjpegServerFramerate,
      "mjpegServerFramerate",
      1,
      60,
    );
  }
  if (body.mjpegScalingFactor !== undefined) {
    settings.mjpegScalingFactor = requireIntInRange(
      body.mjpegScalingFactor,
      "mjpegScalingFactor",
      1,
      100,
    );
  }
  if (body.mjpegServerScreenshotQuality !== undefined) {
    settings.mjpegServerScreenshotQuality = requireIntInRange(
      body.mjpegServerScreenshotQuality,
      "mjpegServerScreenshotQuality",
      1,
      100,
    );
  }
  if (body.mjpegFixOrientation !== undefined) {
    settings.mjpegFixOrientation = Boolean(body.mjpegFixOrientation);
  }
  if (Object.keys(settings).length === 0) {
    const err = new Error("No valid MJPEG settings provided");
    err.status = 400;
    throw err;
  }
  return settings;
}

function getDefaultWdaMjpegSettings() {
  return stabilizeMjpegSettingsForScale(clampWdaMjpegSettings(config.defaultSettings));
}

// The UI remains a 1-100 slider, while WDA receives that percentage of this server-side cap.
function toWdaMjpegSettings(settings) {
  const next = { ...settings };
  if (next.mjpegScalingFactor !== undefined) {
    next.mjpegScalingFactor = clientScaleToWdaScale(next.mjpegScalingFactor);
  }
  return next;
}

function toClientMjpegSettings(wdaSettings, requestedSettings = null) {
  const next = { ...wdaSettings };
  if (next.mjpegScalingFactor !== undefined) {
    next.mjpegScalingFactor =
      requestedSettings?.mjpegScalingFactor !== undefined
        ? requestedSettings.mjpegScalingFactor
        : wdaScaleToClientScale(next.mjpegScalingFactor);
  }
  return next;
}

function clampWdaMjpegSettings(settings) {
  const next = { ...settings };
  if (next.mjpegScalingFactor !== undefined) {
    next.mjpegScalingFactor = clampWdaScale(next.mjpegScalingFactor);
  }
  return next;
}

function clientScaleToWdaScale(scale) {
  const displayScale = requireIntInRange(scale, "mjpegScalingFactor", 1, 100);
  return clampWdaScale(Math.round((displayScale / 100) * config.mjpegWdaScaleMax));
}

function wdaScaleToClientScale(scale) {
  const rawScale = Number(scale);
  if (!Number.isFinite(rawScale)) {
    return 100;
  }
  return Math.max(
    1,
    Math.min(100, Math.round((clampWdaScale(rawScale) / config.mjpegWdaScaleMax) * 100)),
  );
}

function clampWdaScale(scale) {
  const rawScale = Math.round(Number(scale));
  if (!Number.isFinite(rawScale)) {
    return config.mjpegWdaScaleMax;
  }
  return Math.max(1, Math.min(config.mjpegWdaScaleMax, rawScale));
}

function stabilizeMjpegSettingsForScale(settings) {
  const next = { ...settings };
  const scale = Number(next.mjpegScalingFactor);
  if (!Number.isFinite(scale)) {
    return next;
  }

  const defaultFps = requireIntInRange(
    config.defaultSettings.mjpegServerFramerate,
    "mjpegServerFramerate",
    1,
    60,
  );
  const defaultQuality = requireIntInRange(
    config.defaultSettings.mjpegServerScreenshotQuality,
    "mjpegServerScreenshotQuality",
    1,
    100,
  );

  next.mjpegServerFramerate = next.mjpegServerFramerate ?? defaultFps;
  next.mjpegServerScreenshotQuality = Math.min(
    next.mjpegServerScreenshotQuality ?? defaultQuality,
    mjpegQualityLimitForScale(scale),
  );
  return next;
}

function mjpegQualityLimitForScale(scale) {
  if (scale >= 90) {
    return 35;
  }
  if (scale >= 70) {
    return 40;
  }
  if (scale >= 55) {
    return 45;
  }
  if (scale >= 40) {
    return 50;
  }
  return 100;
}

function requireIntInRange(value, name, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || n > max) {
    const err = new Error(`${name} must be a number between ${min} and ${max}`);
    err.status = 400;
    throw err;
  }
  return Math.round(n);
}

function requireNumber(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    const err = new Error(`${name} must be a valid number`);
    err.status = 400;
    throw err;
  }
  return Math.round(n);
}

function optionalNumber(value, name) {
  if (value == null) {
    return undefined;
  }
  const n = Number(value);
  if (!Number.isFinite(n)) {
    const err = new Error(`${name} must be a valid number`);
    err.status = 400;
    throw err;
  }
  return Math.round(n);
}

function optionalBoolean(value) {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") {
    return value !== 0;
  }
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return (
      normalized === "1" ||
      normalized === "true" ||
      normalized === "yes" ||
      normalized === "on"
    );
  }
  return false;
}

function normalizeTouchPayload(raw = {}, options = {}) {
  const payload = {};
  const requirePoint = options.requirePoint !== false;
  const x = requirePoint
    ? requireNumber(raw?.x, "x")
    : optionalNumber(raw?.x, "x");
  const y = requirePoint
    ? requireNumber(raw?.y, "y")
    : optionalNumber(raw?.y, "y");
  if (x !== undefined) {
    payload.x = x;
  }
  if (y !== undefined) {
    payload.y = y;
  }
  const pointerId =
    optionalNumber(raw?.pointerId ?? raw?.finger ?? raw?.pointer, "pointerId") ?? 1;
  payload.pointerId = Math.max(1, pointerId);

  const sequence = optionalNumber(raw?.sequence ?? raw?.seq, "sequence");
  if (sequence !== undefined) {
    payload.sequence = sequence;
  }

  if (raw?.timestamp != null) {
    const timestamp = Number(raw.timestamp);
    if (Number.isFinite(timestamp)) {
      payload.timestamp = timestamp;
    }
  }
  if (raw?.ack != null) {
    payload.ack = optionalBoolean(raw.ack);
  }
  if (raw?.dispatch != null) {
    payload.dispatch = optionalBoolean(raw.dispatch);
  }
  return payload;
}

function normalizePointArray(raw) {
  if (!Array.isArray(raw)) {
    const err = new Error("pointArray must be an array");
    err.status = 400;
    throw err;
  }
  if (raw.length < 2 || raw.length > POINT_ARRAY_MAX_POINTS) {
    const err = new Error(
      `pointArray must contain between 2 and ${POINT_ARRAY_MAX_POINTS} points`,
    );
    err.status = 400;
    throw err;
  }

  const normalized = [];
  let lastOffset = 0;
  for (let i = 0; i < raw.length; i += 1) {
    const item = raw[i];
    if (!Array.isArray(item) || item.length < 2 || item.length > 3) {
      const err = new Error(`pointArray[${i}] must have 2 or 3 numeric values`);
      err.status = 400;
      throw err;
    }
    const x = Number(item[0]);
    const y = Number(item[1]);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      const err = new Error(`pointArray[${i}] coordinates must be finite`);
      err.status = 400;
      throw err;
    }

    let offset = 0;
    if (i === 0) {
      if (item.length === 3) {
        const t0 = Number(item[2]);
        if (!Number.isFinite(t0) || Math.abs(t0) > 1e-6) {
          const err = new Error("pointArray[0] offset must be 0 or omitted");
          err.status = 400;
          throw err;
        }
      }
    } else if (item.length === 3) {
      offset = Number(item[2]);
      if (!Number.isFinite(offset) || offset < lastOffset) {
        const err = new Error(`pointArray[${i}] offset must be monotonic`);
        err.status = 400;
        throw err;
      }
    } else {
      offset = Number((lastOffset + 0.016).toFixed(3));
    }

    if (offset > POINT_ARRAY_MAX_DURATION_SECONDS) {
      const err = new Error(
        `pointArray total duration exceeds ${POINT_ARRAY_MAX_DURATION_SECONDS} seconds`,
      );
      err.status = 400;
      throw err;
    }

    lastOffset = offset;
    normalized.push([Math.round(x), Math.round(y), Number(offset.toFixed(3))]);
  }

  return normalized;
}

function buildPointArraySt(pointArray, secret) {
  const ts = String(Math.floor(Date.now() / 1000));
  const message = `${ts}\n${canonicalPointArray(pointArray)}`;
  const sig = crypto
    .createHmac("sha256", secret)
    .update(message, "utf8")
    .digest("hex");
  return `${ts}.${sig}`;
}

function canonicalPointArray(pointArray) {
  return pointArray
    .map(
      (row) =>
        `${formatFixed6(row[0])},${formatFixed6(row[1])},${formatFixed6(row[2] ?? 0)}`,
    )
    .join(";");
}

function formatFixed6(value) {
  return Number(value).toFixed(6);
}

function stripTrailingSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function numberOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function booleanOr(value, fallback) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  return fallback;
}

function defaultGoIosBin() {
  const localBin = "/Users/apple/.local/bin/ios";
  return fs.existsSync(localBin) ? localBin : "ios";
}

function noop() {}

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return;
  }
  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const eqIndex = trimmed.indexOf("=");
    if (eqIndex <= 0) {
      continue;
    }
    const key = trimmed.slice(0, eqIndex).trim();
    if (!key || process.env[key] !== undefined) {
      continue;
    }
    let value = trimmed.slice(eqIndex + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}
