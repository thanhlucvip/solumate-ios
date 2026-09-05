'use strict';

const VIEW_MODES_FALLBACK = [
  {id: 'mjpeg-wda', label: 'MJPEG WDA', enabled: true},
  {id: 'mjpeg-binary', label: 'MJPEG Binary Socket', enabled: true},
  {id: 'mjpeg-canvas', label: 'MJPEG Canvas Socket', enabled: true},
  {id: 'broadway', label: 'Broadway', enabled: true},
  {id: 'h264-live-player', label: 'h264-live-player', enabled: true},
  {id: 'tinyh264', label: 'tinyh264', enabled: true},
  {id: 'webcodecs', label: 'WebCodecs', enabled: true},
];
const VIEW_MODE_QUERY_KEY = 'viewMode';
const CONTROL_MODE_QUERY_KEY = 'controlMode';
const AUTH_STORAGE_KEY = 'ios_wda_stream_auth_token';
const CONTROL_MODE_STORAGE_KEY = 'ios_wda_control_mode';
const REALTIME_PREFERRED_VIEW_MODES = ['mjpeg-canvas', 'mjpeg-binary', 'mjpeg-wda'];
const CONTROL_MODE_SOCKET_REALTIME = 'realtime-socket';
const CONTROL_MODE_SOCKET_SWIPE = 'realtime-socket-swipe';
const CONTROL_MODE_ALIASES = {
  'realtime-socket': CONTROL_MODE_SOCKET_REALTIME,
  'socket-realtime': CONTROL_MODE_SOCKET_REALTIME,
  'socket-realtime-trollstore': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-control': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-trollstore': CONTROL_MODE_SOCKET_REALTIME,
  'trollstore-realtime': CONTROL_MODE_SOCKET_REALTIME,
  'trollstore-socket': CONTROL_MODE_SOCKET_REALTIME,
  'touch-realtime': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-touch': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket-point-array': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket-pointarray': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket(point-array)': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket(pointarray)': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket(point array)': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-control-mesh': CONTROL_MODE_SOCKET_REALTIME,
  mesh: CONTROL_MODE_SOCKET_REALTIME,
  'mesh-point-array': CONTROL_MODE_SOCKET_REALTIME,
  'mesh-pointarray': CONTROL_MODE_SOCKET_REALTIME,
  'socket-point-array': CONTROL_MODE_SOCKET_REALTIME,
  'socket-pointarray': CONTROL_MODE_SOCKET_REALTIME,
  'point-array-socket': CONTROL_MODE_SOCKET_REALTIME,
  'pointarray-socket': CONTROL_MODE_SOCKET_REALTIME,
  realtime: CONTROL_MODE_SOCKET_REALTIME,
  socket: CONTROL_MODE_SOCKET_REALTIME,
  auto: CONTROL_MODE_SOCKET_REALTIME,
  http: CONTROL_MODE_SOCKET_REALTIME,
  'http-wda': CONTROL_MODE_SOCKET_REALTIME,
  pointarray: CONTROL_MODE_SOCKET_REALTIME,
  'point-array': CONTROL_MODE_SOCKET_REALTIME,
  'http-pointarray': CONTROL_MODE_SOCKET_REALTIME,
  'http-point-array': CONTROL_MODE_SOCKET_REALTIME,
  'realtime-socket-swipe': CONTROL_MODE_SOCKET_SWIPE,
  'realtime-socket(swipe)': CONTROL_MODE_SOCKET_SWIPE,
  'mesh-swipe': CONTROL_MODE_SOCKET_SWIPE,
  'socket-swipe': CONTROL_MODE_SOCKET_SWIPE,
  'swipe-socket': CONTROL_MODE_SOCKET_SWIPE,
  swipe: CONTROL_MODE_SOCKET_SWIPE,
  swip: CONTROL_MODE_SOCKET_SWIPE,
  'http-swipe': CONTROL_MODE_SOCKET_SWIPE,
  'http-swip': CONTROL_MODE_SOCKET_SWIPE,
};
const CONTROL_MODES_FALLBACK = [
  {id: CONTROL_MODE_SOCKET_REALTIME, label: 'realtime-socket', enabled: true, reachable: true},
  {id: CONTROL_MODE_SOCKET_SWIPE, label: 'realtime-socket(swipe)', enabled: true, reachable: true},
];
const CONTROL_SOCKET_MODES = new Set([
  CONTROL_MODE_SOCKET_REALTIME,
  CONTROL_MODE_SOCKET_SWIPE,
]);
const INITIAL_VIEW_MODE = getRequestedViewMode();
const INITIAL_CONTROL_MODE = getRequestedControlMode();
const APP_AUTH_TOKEN = initAuthToken();

const SCRIPT_CACHE = new Map();
const FRAME_IMAGE_VIEW_MODES = ['mjpeg-wda', 'mjpeg-binary', 'mjpeg-canvas'];
const TAP_THRESHOLD_PX = 16;
const POINT_ARRAY_SAMPLE_DISTANCE_PX = 2;
const POINT_ARRAY_DEFAULT_SAMPLE_MS = 16;
const POINT_ARRAY_START_MOVE_DELAY_SECONDS = 0.01;
const SWIPE_MIN_DURATION_SECONDS = 0.03;
const SWIPE_MAX_DURATION_SECONDS = 5;
const H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS = 300;
const CONTROL_COMMAND_TIMEOUT_MS = 3500;
const CONTROL_SOCKET_RECONNECT_MS = 1200;
const REALTIME_TOUCH_MOVE_INTERVAL_MS = 8;
const REALTIME_TOUCH_HOLD_SAMPLE_INTERVAL_MS = 32;
const REALTIME_TOUCH_HOLD_IDLE_MS = 64;
const REALTIME_EDGE_TOUCH_BOTTOM_INSET_PX = 28;
const REALTIME_EDGE_TOUCH_MIN_VERTICAL_DISTANCE_RATIO = 0.12;
const REALTIME_EDGE_TOUCH_TOP_TARGET_RATIO = 0.045;
const REALTIME_TOUCH_DEBUG = getRequestedRealtimeTouchDebug();

const state = {
  screen: null,
  sessionId: null,
  dragging: false,
  dragStart: null,
  dragLastPoint: null,
  dragDistance: 0,
  dragSamples: [],
  liveTouchActive: false,
  liveTouchFailed: false,
  liveTouchBroken: false,
  liveTouchPointerId: 0,
  liveTouchSequence: 1,
  liveTouchLastPoint: null,
  liveTouchPendingMove: null,
  liveTouchMoveTimer: 0,
  liveTouchHoldTimer: 0,
  liveTouchLastPointerMoveAt: 0,
  liveTouchStartPromise: null,
  liveTouchTransport: '',
  touchIndicator: null,
  touchHideTimer: 0,
  hoverIndicator: null,
  viewModes: VIEW_MODES_FALLBACK,
  viewModeMap: new Map(),
  selectedMode: INITIAL_VIEW_MODE || '',
  controlModes: CONTROL_MODES_FALLBACK,
  controlModeMap: new Map(),
  selectedControlMode: INITIAL_CONTROL_MODE || '',
  controlClient: null,
  controlClientEndpoint: '',
  renderer: null,
  activeSurface: null,
  viewerAspect: 0,
  streamConfig: null,
  controlStream: null,
};

const el = {
  connectBtn: document.getElementById('connectBtn'),
  homeBtn: document.getElementById('homeBtn'),
  restartSessionBtn: document.getElementById('restartSessionBtn'),
  statusBtn: document.getElementById('statusBtn'),
  screenBtn: document.getElementById('screenBtn'),
  applySettingsBtn: document.getElementById('applySettingsBtn'),
  applyViewBtn: document.getElementById('applyViewBtn'),
  viewModeSelect: document.getElementById('viewModeSelect'),
  viewModeLabel: document.getElementById('viewModeLabel'),
  controlModeSelect: document.getElementById('controlModeSelect'),
  controlModeLabel: document.getElementById('controlModeLabel'),
  controlStateLabel: document.getElementById('controlStateLabel'),
  fpsInput: document.getElementById('fpsInput'),
  fpsValue: document.getElementById('fpsValue'),
  qualityInput: document.getElementById('qualityInput'),
  qualityValue: document.getElementById('qualityValue'),
  scaleInput: document.getElementById('scaleInput'),
  scaleValue: document.getElementById('scaleValue'),
  fixOrientationInput: document.getElementById('fixOrientationInput'),
  pointArraySampleMsInput: document.getElementById('pointArraySampleMsInput'),
  viewer: document.getElementById('viewer'),
  streamHost: document.getElementById('streamHost'),
  gestureOverlay: document.getElementById('gestureOverlay'),
  streamState: document.getElementById('streamState'),
  logBox: document.getElementById('logBox'),
  sessionIdLabel: document.getElementById('sessionIdLabel'),
  screenInfoLabel: document.getElementById('screenInfoLabel'),
  wdaBaseLabel: document.getElementById('wdaBaseLabel'),
  h264SourceLabel: document.getElementById('h264SourceLabel'),
  scrcpySourceLabel: document.getElementById('scrcpySourceLabel'),
  webrtcSourceLabel: document.getElementById('webrtcSourceLabel'),
};

init().catch((err) => log(err.message || String(err), true));

async function init() {
  bindUi();
  await loadHealth();
  await loadViewModes();
  await loadControlModes();
  try {
    await connect();
  } catch (err) {
    showError(err);
    await applySelectedViewMode(true);
  }
}

function bindUi() {
  el.connectBtn.addEventListener('click', () => connect().catch(showError));
  el.homeBtn.addEventListener('click', () => sendHomeControl().then((data) => logData('HOME', data)).catch(showError));
  el.restartSessionBtn.addEventListener('click', () => connect(true).catch(showError));
  el.statusBtn.addEventListener('click', () => apiGet('/api/status').then((data) => logData('STATUS', data)).catch(showError));
  el.screenBtn.addEventListener('click', async () => {
    const data = await apiGet('/api/screen');
    applyScreenInfo(data);
    logData('SCREEN', data);
  });
  el.applySettingsBtn.addEventListener('click', () => applySettings().catch(showError));
  el.applyViewBtn.addEventListener('click', () => applySelectedViewMode(true).catch(showError));
  el.viewModeSelect.addEventListener('change', () => {
    const mode = el.viewModeSelect.value;
    el.viewModeLabel.textContent = mode || '-';
    persistRequestedViewMode(mode);
  });
  el.controlModeSelect.addEventListener('change', () => {
    const mode = normalizeControlModeId(el.controlModeSelect.value) || CONTROL_MODE_SOCKET_REALTIME;
    setControlModeLabel(mode);
    persistRequestedControlMode(mode);
    applySelectedControlMode(true).catch(showError);
  });
  bindRangeSetting(el.fpsInput, el.fpsValue, ' fps');
  bindRangeSetting(el.qualityInput, el.qualityValue, '%');
  bindRangeSetting(el.scaleInput, el.scaleValue, '%');
  syncRangeSettingDisplays();

  el.viewer.addEventListener('pointerenter', (event) => {
    if (event.pointerType === 'mouse') {
      showHoverIndicator(event.clientX, event.clientY);
    }
  });

  el.viewer.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    hideHoverIndicator();
    const point = eventToDevicePoint(event);
    if (!point) {
      return;
    }
    state.dragging = true;
    state.dragStart = point;
    state.dragLastPoint = point;
    state.dragDistance = 0;
    state.dragSamples = [];
    if (state.liveTouchMoveTimer) {
      window.clearTimeout(state.liveTouchMoveTimer);
      state.liveTouchMoveTimer = 0;
    }
    stopRealtimeTouchHoldSampler();
    state.liveTouchActive = false;
    state.liveTouchFailed = false;
    state.liveTouchBroken = false;
    state.liveTouchPointerId = 0;
    state.liveTouchLastPoint = null;
    state.liveTouchPendingMove = null;
    state.liveTouchLastPointerMoveAt = 0;
    state.liveTouchTransport = '';
    state.liveTouchStartPromise = null;
    recordDragSample(point, true);
    showTouchIndicator(event.clientX, event.clientY);
    el.viewer.setPointerCapture?.(event.pointerId);
    if (shouldBeginRealtimeEdgeTouch(point)) {
      beginRealtimeTouchStream(event.pointerId);
    }
  });

  el.viewer.addEventListener('pointermove', (event) => {
    if (!state.dragging || !state.dragStart) {
      if (event.pointerType === 'mouse') {
        showHoverIndicator(event.clientX, event.clientY);
      }
      return;
    }
    const point = eventToDevicePoint(event);
    if (!point) {
      return;
    }
    if (state.dragLastPoint) {
      state.dragDistance += Math.hypot(point.x - state.dragLastPoint.x, point.y - state.dragLastPoint.y);
    }
    state.dragLastPoint = point;
    state.liveTouchLastPointerMoveAt = Date.now();
    recordDragSample(point, false);
    showTouchIndicator(event.clientX, event.clientY);
    if (shouldUseRealtimeTouchStream() && !state.liveTouchActive && !state.liveTouchFailed && state.dragStart) {
      const directDistance = Math.hypot(point.x - state.dragStart.x, point.y - state.dragStart.y);
      if (directDistance >= TAP_THRESHOLD_PX) {
        beginRealtimeTouchStream(event.pointerId);
      }
    }
    if (state.liveTouchActive) {
      state.liveTouchLastPoint = point;
      queueRealtimeTouchMove(point);
    }
  });

  el.viewer.addEventListener('pointerup', async (event) => {
    if (!state.dragging || !state.dragStart) {
      if (event.pointerType === 'mouse') {
        showHoverIndicator(event.clientX, event.clientY);
      }
      return;
    }
    const end = eventToDevicePoint(event);
    showTouchIndicator(event.clientX, event.clientY);
    if (event.pointerType === 'mouse') {
      showHoverIndicator(event.clientX, event.clientY);
    }
    state.dragging = false;
    if (!end) {
      cancelRealtimeTouchStream().catch((err) => log(`TOUCH_CANCEL failed: ${err.message}`, true));
      state.dragStart = null;
      resetDragTracking();
      return;
    }
    const start = state.dragStart;
    state.dragStart = null;
    if (state.dragLastPoint) {
      state.dragDistance += Math.hypot(end.x - state.dragLastPoint.x, end.y - state.dragLastPoint.y);
    }
    state.dragLastPoint = end;
    state.liveTouchLastPoint = end;
    stopRealtimeTouchHoldSampler();
    recordDragSample(end, true);
    const directDistance = Math.hypot(end.x - start.x, end.y - start.y);
    const distance = Math.max(directDistance, state.dragDistance);
    if (!state.liveTouchActive || state.liveTouchFailed) {
      hideTouchIndicator();
      try {
        await sendRecordedGestureFallback(start, end, distance, event);
      } finally {
        state.liveTouchActive = false;
        state.liveTouchFailed = false;
        state.liveTouchPointerId = 0;
        state.liveTouchLastPoint = null;
        state.liveTouchLastPointerMoveAt = 0;
        state.liveTouchStartPromise = null;
        state.liveTouchTransport = '';
        resetDragTracking();
      }
      return;
    }
    if (state.liveTouchBroken) {
      hideTouchIndicator();
      try {
        await cancelRealtimeTouchStream();
      } finally {
        state.liveTouchActive = false;
        state.liveTouchPointerId = 0;
        state.liveTouchLastPoint = null;
        state.liveTouchLastPointerMoveAt = 0;
        state.liveTouchStartPromise = null;
        state.liveTouchTransport = '';
        resetDragTracking();
      }
      return;
    }
    try {
      if (state.liveTouchStartPromise) {
        await state.liveTouchStartPromise;
      }
      if (!state.liveTouchActive || state.liveTouchFailed) {
        await sendRecordedGestureFallback(start, end, distance, event);
        return;
      }
      await flushRealtimeTouchMove();
      const finalPoint = realtimeEdgeTouchEndPoint(start, end, distance);
      if (finalPoint.x !== end.x || finalPoint.y !== end.y) {
        state.liveTouchLastPoint = finalPoint;
        queueRealtimeTouchMove(finalPoint, {edge: true});
        await flushRealtimeTouchMove();
      }
      const data = await sendRealtimeTouchUp(finalPoint, event.pointerId);
      logData('TOUCH_STREAM', {
        from: start,
        to: finalPoint,
        pointerEnd: end,
        samples: state.dragSamples.length,
        response: data,
      });
    } catch (err) {
      state.liveTouchBroken = true;
      log(`TOUCH_STREAM failed: ${err.message}`, true);
      await cancelRealtimeTouchStream().catch(() => {});
    } finally {
      hideTouchIndicator();
      state.liveTouchActive = false;
      state.liveTouchPointerId = 0;
      state.liveTouchLastPoint = null;
      state.liveTouchLastPointerMoveAt = 0;
      state.liveTouchFailed = false;
      state.liveTouchBroken = false;
      state.liveTouchStartPromise = null;
      state.liveTouchTransport = '';
      resetDragTracking();
    }
  });

  el.viewer.addEventListener('pointercancel', () => {
    if (state.dragging) {
      cancelRealtimeTouchStream().catch((err) => log(`TOUCH_CANCEL failed: ${err.message}`, true));
      state.dragging = false;
      state.dragStart = null;
      resetDragTracking();
      hideTouchIndicator();
    }
    hideHoverIndicator();
  });

  el.viewer.addEventListener('pointerleave', () => {
    if (!state.dragging) {
      hideHoverIndicator();
    }
  });

  window.addEventListener('blur', () => {
    if (state.dragging) {
      cancelRealtimeTouchStream().catch((err) => log(`TOUCH_CANCEL failed: ${err.message}`, true));
      state.dragging = false;
      state.dragStart = null;
      resetDragTracking();
      hideTouchIndicator();
    }
  });

  window.addEventListener('resize', () => {
    fitActiveMjpegSurface();
  });
}

async function loadHealth() {
  const health = await apiGet('/health');
  el.wdaBaseLabel.textContent = health.config.wdaBase;
}

async function loadViewModes() {
  const hiddenWhenUnreachable = new Set(['webrtc-h264']);
  let viewData;
  try {
    viewData = await apiGet('/api/view-modes');
  } catch (err) {
    log(`Cannot load /api/view-modes, fallback to local defaults: ${err.message}`);
    viewData = {modes: VIEW_MODES_FALLBACK, endpoints: {}, upstream: {}};
  }

  const modes = Array.isArray(viewData?.modes) && viewData.modes.length
    ? viewData.modes
    : VIEW_MODES_FALLBACK;

  state.streamConfig = viewData || {};
  state.viewModes = modes.map((item) => ({
    id: String(item.id),
    label: String(item.label || item.id),
    enabled: item.enabled !== false,
    reachable: item.reachable !== false,
    sourceKind: typeof item.sourceKind === 'string' ? item.sourceKind : '',
    reasonIfUnavailable: typeof item.reasonIfUnavailable === 'string' ? item.reasonIfUnavailable : '',
    warningIfUnreachable: typeof item.warningIfUnreachable === 'string' ? item.warningIfUnreachable : '',
  })).filter((item) => !(hiddenWhenUnreachable.has(item.id) && !item.reachable));
  state.viewModeMap = new Map(state.viewModes.map((item) => [item.id, item]));

  const preferredMode = choosePreferredViewMode(state.selectedMode, state.viewModes);
  state.selectedMode = preferredMode;
  persistRequestedViewMode(preferredMode);

  el.viewModeSelect.innerHTML = '';
  for (const mode of state.viewModes) {
    const option = document.createElement('option');
    option.value = mode.id;
    if (!mode.enabled) {
      option.textContent = `${mode.label} (disabled: ${mode.reasonIfUnavailable || 'unavailable'})`;
    } else if (mode.warningIfUnreachable && mode.reachable === false) {
      option.textContent = `${mode.label} (warning: source unreachable)`;
    } else {
      option.textContent = mode.label;
    }
    if (!mode.enabled && mode.reasonIfUnavailable) {
      option.title = mode.reasonIfUnavailable;
    } else if (mode.enabled && mode.warningIfUnreachable) {
      option.title = mode.warningIfUnreachable;
    }
    option.disabled = !mode.enabled;
    if (mode.id === preferredMode) {
      option.selected = true;
    }
    el.viewModeSelect.appendChild(option);
  }

  el.viewModeLabel.textContent = preferredMode || '-';
  const upstream = state.streamConfig?.upstream || {};
  const localFallback = upstream.localH264Fallback || null;
  const localLabel = localFallback?.enabled
    ? `local-mjpeg-bridge (${localFallback.source || 'mjpeg'})`
    : '-';
  el.h264SourceLabel.textContent = localLabel;
  el.scrcpySourceLabel.textContent = localLabel;
  el.webrtcSourceLabel.textContent = upstream.webrtcWhepUrl || '-';
}

async function loadControlModes() {
  let controlData;
  try {
    controlData = await apiGet('/api/control-modes');
  } catch (err) {
    log(`Cannot load /api/control-modes, fallback to local defaults: ${err.message}`);
    controlData = {modes: CONTROL_MODES_FALLBACK, endpoints: {}, upstream: {}};
  }

  const modes = Array.isArray(controlData?.modes) && controlData.modes.length
    ? controlData.modes
    : CONTROL_MODES_FALLBACK;

  state.controlStream = controlData || {};
  state.controlModes = normalizeControlModes(modes);
  state.controlModeMap = new Map(state.controlModes.map((item) => [item.id, item]));

  const preferredMode = choosePreferredControlMode(state.selectedControlMode, state.controlModes);
  state.selectedControlMode = preferredMode;
  persistRequestedControlMode(preferredMode);

  el.controlModeSelect.innerHTML = '';
  for (const mode of state.controlModes) {
    const option = document.createElement('option');
    option.value = mode.id;
    option.textContent = mode.warningIfUnreachable && mode.reachable === false
      ? `${mode.label} (warning: source unreachable)`
      : mode.label;
    if (mode.warningIfUnreachable) {
      option.title = mode.warningIfUnreachable;
    }
    option.disabled = !mode.enabled;
    if (mode.id === preferredMode) {
      option.selected = true;
    }
    el.controlModeSelect.appendChild(option);
  }

  setControlModeLabel(preferredMode);
  const upstream = state.controlStream?.upstream || {};
  const realtimeUrl = getControlModeUrl(preferredMode) || '-';
  if (preferredMode === CONTROL_MODE_SOCKET_REALTIME) {
    setControlState(isControlSocketReachable(preferredMode) ? 'realtime socket available' : 'realtime socket unavailable');
  } else if (preferredMode === CONTROL_MODE_SOCKET_SWIPE) {
    setControlState(isControlSocketReachable(preferredMode) ? 'mesh swipe socket available' : 'mesh swipe socket unavailable');
  } else {
    setControlState('http fallback');
  }
  if (el.controlStateLabel) {
    el.controlStateLabel.title = realtimeUrl;
  }
}

function choosePreferredViewMode(selectedMode, modes) {
  const selected = selectedMode ? modes.find((item) => item.id === selectedMode) : null;
  if (selected?.enabled) {
    return selected.id;
  }

  for (const preferredId of REALTIME_PREFERRED_VIEW_MODES) {
    const preferred = modes.find((item) => item.id === preferredId);
    if (preferred?.enabled && preferred.reachable !== false) {
      return preferred.id;
    }
  }

  return modes.find((item) => item.id === 'mjpeg-wda' && item.enabled)?.id
    || modes.find((item) => item.id === 'mjpeg-binary' && item.enabled)?.id
    || modes.find((item) => item.enabled)?.id
    || modes[0]?.id
    || 'mjpeg-wda';
}

function normalizeControlModes(modes) {
  const normalizedModes = [];
  const seen = new Set();
  for (const item of modes) {
    const id = normalizeControlModeId(item?.id);
    if (!id || seen.has(id)) {
      continue;
    }
    const fallback = CONTROL_MODES_FALLBACK.find((mode) => mode.id === id);
    normalizedModes.push({
      id,
      label: fallback?.label || String(item.label || id),
      enabled: item.enabled !== false,
      reachable: item.reachable !== false,
      warningIfUnreachable: typeof item.warningIfUnreachable === 'string' ? item.warningIfUnreachable : '',
    });
    seen.add(id);
  }
  for (const fallback of CONTROL_MODES_FALLBACK) {
    if (!seen.has(fallback.id)) {
      normalizedModes.push({...fallback});
    }
  }
  return normalizedModes;
}

function normalizeControlModeId(mode) {
  const raw = String(mode || '').trim().toLowerCase();
  return CONTROL_MODE_ALIASES[raw] || '';
}

function getControlModeLabel(mode) {
  const normalized = normalizeControlModeId(mode) || mode;
  return state.controlModeMap.get(normalized)?.label
    || CONTROL_MODES_FALLBACK.find((item) => item.id === normalized)?.label
    || normalized
    || '-';
}

function setControlModeLabel(mode) {
  if (el.controlModeLabel) {
    el.controlModeLabel.textContent = getControlModeLabel(mode);
  }
}

function isControlSocketReachable(mode) {
  const upstream = state.controlStream?.upstream || {};
  const normalizedMode = normalizeControlModeId(mode);
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return upstream.realtimeReachable !== false;
  }
  return upstream.realtimeControlMeshReachable ?? upstream.realtimeReachable ?? true;
}

function getControlModeUrl(mode) {
  const upstream = state.controlStream?.upstream || {};
  const normalizedMode = normalizeControlModeId(mode);
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return upstream.realtimeControlUrl || '';
  }
  return upstream.realtimeControlMeshUrl || upstream.realtimeControlUrl || '';
}

function choosePreferredControlMode(selectedMode, modes) {
  const normalizedSelectedMode = normalizeControlModeId(selectedMode);
  const selected = normalizedSelectedMode
    ? modes.find((item) => item.id === normalizedSelectedMode)
    : null;
  if (selected?.enabled) {
    return selected.id;
  }

  return modes.find((item) => item.id === CONTROL_MODE_SOCKET_REALTIME && item.enabled)?.id
    || modes.find((item) => item.id === CONTROL_MODE_SOCKET_SWIPE && item.enabled)?.id
    || modes.find((item) =>
      item.id === CONTROL_MODE_SOCKET_REALTIME &&
      item.enabled &&
      item.reachable
    )?.id
    || modes.find((item) => item.enabled)?.id
    || modes[0]?.id
    || CONTROL_MODE_SOCKET_REALTIME;
}

async function connect(forceRestart = false) {
  setStreamState('connecting WDA...', false);
  const data = await apiPost('/api/connect', forceRestart ? {forceRestart: true} : {});
  state.sessionId = data.sessionId || null;
  el.sessionIdLabel.textContent = state.sessionId || '-';
  applyScreenInfo(data.screen || null);
  applySettingsInputs(data.settings || null);
  logData('CONNECT', data);
  await Promise.all([
    applySelectedViewMode(true),
    applySelectedControlMode(true),
  ]);
  return data;
}

async function applySelectedViewMode(force = false) {
  const mode = el.viewModeSelect.value || state.selectedMode;
  if (!mode) {
    throw new Error('No view mode selected');
  }
  const modeInfo = state.viewModeMap.get(mode);
  if (modeInfo && !modeInfo.enabled) {
    throw new Error(`View mode "${mode}" is disabled by server config`);
  }
  if (!force && state.renderer && state.selectedMode === mode) {
    return;
  }

  setStreamState(`switching view: ${mode}`, false);
  await stopRenderer();
  const renderer = await createRenderer(mode);
  state.renderer = renderer;
  state.selectedMode = mode;
  persistRequestedViewMode(mode);
  el.viewModeLabel.textContent = mode;
  await renderer.start();
}

function getRequestedViewMode() {
  try {
    const url = new URL(window.location.href);
    const raw = url.searchParams.get(VIEW_MODE_QUERY_KEY);
    if (!raw) {
      return '';
    }
    return String(raw).trim();
  } catch (err) {
    return '';
  }
}

function getRequestedControlMode() {
  try {
    const url = new URL(window.location.href);
    const raw = url.searchParams.get(CONTROL_MODE_QUERY_KEY);
    if (raw) {
      return normalizeControlModeId(raw);
    }
    return normalizeControlModeId(localStorage.getItem(CONTROL_MODE_STORAGE_KEY));
  } catch (err) {
    return '';
  }
}

function getRequestedRealtimeTouchDebug() {
  try {
    const url = new URL(window.location.href);
    const raw = url.searchParams.get('rtDebug');
    if (raw) {
      const normalized = String(raw).trim().toLowerCase();
      if (['1', 'true', 'yes', 'on'].includes(normalized)) {
        return true;
      }
    }
    const stored = String(localStorage.getItem('ios_wda_rt_debug') || '').trim().toLowerCase();
    return ['1', 'true', 'yes', 'on'].includes(stored);
  } catch (err) {
    return false;
  }
}

function persistRequestedViewMode(mode) {
  try {
    const nextMode = typeof mode === 'string' ? mode.trim() : '';
    const url = new URL(window.location.href);
    if (nextMode) {
      url.searchParams.set(VIEW_MODE_QUERY_KEY, nextMode);
    } else {
      url.searchParams.delete(VIEW_MODE_QUERY_KEY);
    }
    const nextUrl = `${url.pathname}${url.search}${url.hash}`;
    window.history.replaceState(window.history.state, '', nextUrl);
  } catch (err) {
    // Ignore URL persistence errors and keep stream controls working.
  }
}

function persistRequestedControlMode(mode) {
  try {
    const nextMode = normalizeControlModeId(mode);
    if (nextMode) {
      localStorage.setItem(CONTROL_MODE_STORAGE_KEY, nextMode);
    } else {
      localStorage.removeItem(CONTROL_MODE_STORAGE_KEY);
    }
    const url = new URL(window.location.href);
    if (nextMode) {
      url.searchParams.set(CONTROL_MODE_QUERY_KEY, nextMode);
    } else {
      url.searchParams.delete(CONTROL_MODE_QUERY_KEY);
    }
    const nextUrl = `${url.pathname}${url.search}${url.hash}`;
    window.history.replaceState(window.history.state, '', nextUrl);
  } catch (err) {
    // Ignore URL persistence errors and keep controls working.
  }
}

async function stopRenderer() {
  if (!state.renderer) {
    return;
  }
  try {
    await state.renderer.stop?.();
  } catch (err) {
    log(`Renderer stop warning: ${err.message}`);
  }
  state.renderer = null;
  state.activeSurface = null;
  el.streamHost.innerHTML = '';
}

async function createRenderer(mode) {
  if (mode === 'mjpeg-wda') {
    return createMjpegWdaRenderer();
  }
  if (mode === 'mjpeg-binary') {
    return createMjpegBinaryRenderer();
  }
  if (mode === 'mjpeg-canvas') {
    return createMjpegCanvasRenderer();
  }
  if (mode === 'broadway') {
    return createBroadwayRenderer(mode);
  }
  if (mode === 'h264-live-player') {
    return createMseH264Renderer(mode, {source: 'h264'});
  }
  if (mode === 'scrcpy') {
    return createMseH264Renderer(mode, {source: 'scrcpy'});
  }
  if (mode === 'tinyh264') {
    return createTinyH264Renderer();
  }
  if (mode === 'webcodecs') {
    try {
      return createWebCodecsRenderer(mode);
    } catch (err) {
      log(`WebCodecs unavailable, fallback to h264-live-player: ${err.message}`);
      return createBroadwayRenderer(mode, {source: 'h264', useWorker: true});
    }
  }
  if (mode === 'webrtc-h264') {
    return createWebRtcRenderer();
  }
  throw new Error(`Unsupported mode: ${mode}`);
}

function createMjpegWdaRenderer() {
  const image = document.createElement('img');
  image.className = 'stream-media';
  image.alt = 'MJPEG WDA stream';
  image.decoding = 'async';
  const endpoint = getEndpoint('mjpegHttp', '/stream.mjpeg');
  let active = false;
  let geometryTimer = 0;
  let lastFrameWidth = 0;
  let lastFrameHeight = 0;

  const syncFrameGeometry = () => {
    if (!active) {
      return;
    }
    const width = Number(image.naturalWidth) || 0;
    const height = Number(image.naturalHeight) || 0;
    if (
      width <= 0 ||
      height <= 0 ||
      (width === lastFrameWidth && height === lastFrameHeight)
    ) {
      return;
    }
    lastFrameWidth = width;
    lastFrameHeight = height;
    fitMjpegSurfaceToViewer(image);

    // A multipart MJPEG <img> does not fire a new load event when the device
    // rotates. Refresh WDA's logical screen size when the frame dimensions
    // change, then re-apply the frame aspect in case WDA is briefly stale.
    apiGet('/api/screen')
      .then((screen) => {
        if (!active) {
          return;
        }
        applyScreenInfo(screen);
        fitMjpegSurfaceToViewer(image);
      })
      .catch((err) => log(`Cannot refresh screen geometry: ${err.message}`));
  };

  image.addEventListener('load', () => {
    if (active) {
      syncFrameGeometry();
      setStreamState('streaming (mjpeg)', true);
    }
  });
  image.addEventListener('error', () => {
    if (active) {
      setStreamState('stream error', false);
    }
  });

  return {
    async start() {
      active = true;
      mountSurface(image, 'mjpeg-wda');
      geometryTimer = window.setInterval(syncFrameGeometry, 250);
      image.src = appendAuthQuery(appendQueryParam(endpoint, 'ts', Date.now()));
    },
    async stop() {
      active = false;
      if (geometryTimer) {
        window.clearInterval(geometryTimer);
        geometryTimer = 0;
      }
      lastFrameWidth = 0;
      lastFrameHeight = 0;
      image.removeAttribute('src');
    },
  };
}

function createMjpegBinaryRenderer() {
  const surface = document.createElement('div');
  surface.className = 'stream-media mjpeg-binary-surface';
  surface.setAttribute('role', 'img');
  surface.setAttribute('aria-label', 'MJPEG binary websocket stream');
  const frameElements = [document.createElement('img'), document.createElement('img')];
  for (const frameElement of frameElements) {
    frameElement.className = 'mjpeg-binary-frame';
    frameElement.alt = '';
    frameElement.decoding = 'async';
    frameElement.draggable = false;
    surface.appendChild(frameElement);
  }
  const endpoint = getEndpoint('mjpegWs', '/ws/mjpeg');
  let socket = null;
  let active = false;
  let visibleFrameIndex = -1;
  let loadingFrameIndex = -1;
  const frameObjectUrls = ['', ''];
  let loadingObjectUrl = '';
  let pendingObjectUrl = '';
  let frameLoading = false;
  let swapFrameRequest = 0;

  const applyLoadedFrameSize = (frameElement) => {
    const width = Number(frameElement.naturalWidth) || 0;
    const height = Number(frameElement.naturalHeight) || 0;
    if (width <= 0 || height <= 0) {
      return;
    }
    surface.dataset.frameWidth = String(width);
    surface.dataset.frameHeight = String(height);
    applyViewerAspect(width, height);
  };

  const revokeFrameUrl = (index) => {
    const url = frameObjectUrls[index];
    if (url) {
      URL.revokeObjectURL(url);
      frameObjectUrls[index] = '';
    }
    frameElements[index].removeAttribute('src');
  };

  const finishLoadingFrame = (index) => {
    if (!active || index !== loadingFrameIndex || frameObjectUrls[index] !== loadingObjectUrl) {
      return;
    }
    const loadedObjectUrl = loadingObjectUrl;
    const previousFrameIndex = visibleFrameIndex;
    applyLoadedFrameSize(frameElements[index]);
    swapFrameRequest = window.requestAnimationFrame(() => {
      swapFrameRequest = 0;
      if (!active || frameObjectUrls[index] !== loadedObjectUrl) {
        if (frameObjectUrls[index] === loadedObjectUrl) {
          revokeFrameUrl(index);
        }
        loadingFrameIndex = -1;
        loadingObjectUrl = '';
        frameLoading = false;
        return;
      }
      frameElements[index].classList.add('active');
      if (previousFrameIndex >= 0 && previousFrameIndex !== index) {
        frameElements[previousFrameIndex].classList.remove('active');
        revokeFrameUrl(previousFrameIndex);
      }
      visibleFrameIndex = index;
      loadingFrameIndex = -1;
      loadingObjectUrl = '';
      frameLoading = false;
      setStreamState('streaming (mjpeg binary)', true);
      pumpLatestFrame();
    });
  };

  const failLoadingFrame = (index) => {
    if (index !== loadingFrameIndex) {
      return;
    }
    revokeFrameUrl(index);
    loadingFrameIndex = -1;
    loadingObjectUrl = '';
    frameLoading = false;
    pumpLatestFrame();
  };

  const pumpLatestFrame = () => {
    if (!active || frameLoading || !pendingObjectUrl) {
      return;
    }
    const nextFrameIndex = visibleFrameIndex === 0 ? 1 : 0;
    if (frameObjectUrls[nextFrameIndex]) {
      revokeFrameUrl(nextFrameIndex);
    }
    frameLoading = true;
    loadingFrameIndex = nextFrameIndex;
    loadingObjectUrl = pendingObjectUrl;
    pendingObjectUrl = '';
    frameObjectUrls[nextFrameIndex] = loadingObjectUrl;
    frameElements[nextFrameIndex].src = loadingObjectUrl;
  };

  frameElements.forEach((frameElement, index) => {
    frameElement.addEventListener('load', () => finishLoadingFrame(index));
    frameElement.addEventListener('error', () => failLoadingFrame(index));
  });

  return {
    async start() {
      active = true;
      mountSurface(surface, 'mjpeg-binary');
      socket = openAppWebSocket(appendQueryParam(endpoint, 'fps', getCurrentMjpegFps()));
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState('connected (mjpeg binary)', true);
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, 'mjpeg-binary');
          return;
        }
        const blob = new Blob([event.data], {type: 'image/jpeg'});
        const nextUrl = URL.createObjectURL(blob);
        if (pendingObjectUrl) {
          URL.revokeObjectURL(pendingObjectUrl);
        }
        pendingObjectUrl = nextUrl;
        pumpLatestFrame();
      });
      socket.addEventListener('close', () => {
        setStreamState('binary socket closed', false);
      });
      socket.addEventListener('error', () => {
        setStreamState('binary socket error', false);
      });
    },
    async stop() {
      active = false;
      if (socket) {
        socket.close();
        socket = null;
      }
      if (swapFrameRequest) {
        window.cancelAnimationFrame(swapFrameRequest);
        swapFrameRequest = 0;
      }
      if (pendingObjectUrl) {
        URL.revokeObjectURL(pendingObjectUrl);
      }
      for (let index = 0; index < frameElements.length; index += 1) {
        frameElements[index].classList.remove('active');
        revokeFrameUrl(index);
      }
      visibleFrameIndex = -1;
      loadingFrameIndex = -1;
      loadingObjectUrl = '';
      pendingObjectUrl = '';
      frameLoading = false;
      delete surface.dataset.frameWidth;
      delete surface.dataset.frameHeight;
    },
  };
}

function createMjpegCanvasRenderer() {
  const canvas = document.createElement('canvas');
  canvas.className = 'stream-media';
  const context = canvas.getContext('2d', {alpha: false, desynchronized: true});
  if (!context) {
    throw new Error('Cannot create canvas context for MJPEG renderer');
  }

  const endpoint = getEndpoint('mjpegWs', '/ws/mjpeg');
  let socket = null;
  let active = false;
  let pendingFrame = null;
  let decoding = false;

  const drawBitmap = (bitmap) => {
    if (!active || !bitmap) {
      return;
    }
    const width = Number(bitmap.width || bitmap.naturalWidth) || 0;
    const height = Number(bitmap.height || bitmap.naturalHeight) || 0;
    if (width <= 0 || height <= 0) {
      return;
    }
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      applyViewerAspect(width, height);
    }
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  };

  const decodeWithImageElement = (blob) => new Promise((resolve, reject) => {
    const image = new Image();
    const objectUrl = URL.createObjectURL(blob);
    image.onload = () => {
      try {
        drawBitmap(image);
        resolve();
      } finally {
        URL.revokeObjectURL(objectUrl);
      }
    };
    image.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error('Cannot decode MJPEG frame'));
    };
    image.src = objectUrl;
  });

  const decodeAndDraw = async (frame) => {
    const blob = new Blob([frame], {type: 'image/jpeg'});
    if (typeof window.createImageBitmap === 'function') {
      const bitmap = await window.createImageBitmap(blob);
      try {
        drawBitmap(bitmap);
      } finally {
        bitmap.close?.();
      }
      return;
    }
    await decodeWithImageElement(blob);
  };

  const pumpLatestFrame = () => {
    if (!active || decoding || !pendingFrame) {
      return;
    }
    const frame = pendingFrame;
    pendingFrame = null;
    decoding = true;
    decodeAndDraw(frame)
      .then(() => {
        setStreamState('streaming (mjpeg canvas)', true);
      })
      .catch((err) => {
        log(`MJPEG canvas decode warning: ${err.message}`);
      })
      .finally(() => {
        decoding = false;
        pumpLatestFrame();
      });
  };

  return {
    async start() {
      active = true;
      mountSurface(canvas, 'mjpeg-canvas');
      socket = openAppWebSocket(appendQueryParam(endpoint, 'fps', getCurrentMjpegFps()));
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState('connected (mjpeg canvas)', true);
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, 'mjpeg-canvas');
          return;
        }
        pendingFrame = event.data;
        pumpLatestFrame();
      });
      socket.addEventListener('close', () => {
        setStreamState('mjpeg canvas socket closed', false);
      });
      socket.addEventListener('error', () => {
        setStreamState('mjpeg canvas socket error', false);
      });
    },
    async stop() {
      active = false;
      pendingFrame = null;
      decoding = false;
      if (socket) {
        socket.close();
        socket = null;
      }
    },
  };
}

async function createBroadwayRenderer(mode, options = {}) {
  await ensureBroadwayLoaded();
  if (typeof window.Player !== 'function') {
    throw new Error('Broadway player scripts are not loaded');
  }

  const requestedSource = typeof options.source === 'string' && options.source.trim()
    ? options.source.trim()
    : 'h264';
  const useWorker = options.useWorker !== undefined ? Boolean(options.useWorker) : mode === 'h264-live-player';
  const player = new window.Player({
    useWorker,
    workerFile: '/vendors/broadway/Decoder.js',
    webgl: 'auto',
    reuseMemory: true,
    size: getInitialVideoSize(),
  });
  const canvas = player.canvas;
  canvas.className = 'stream-media';
  const endpoint = `${getEndpoint('h264Ws', '/ws/h264')}?source=${encodeURIComponent(requestedSource)}`;

  let socket = null;
  let queue = [];
  let frameLoopId = 0;
  let running = true;
  let waitingForKeyframe = false;
  let lastKeyframeRequestAt = 0;
  const decodeBudgetPerTick = mode === 'h264-live-player' ? 2 : 1;
  const maxQueueSize = mode === 'h264-live-player' ? 4 : 3;

  const requestKeyframe = () => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return;
    }
    const now = Date.now();
    if (now - lastKeyframeRequestAt < H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS) {
      return;
    }
    lastKeyframeRequestAt = now;
    socket.send(JSON.stringify({type: 'request-keyframe'}));
  };

  const decodeFrame = (frame) => {
    if (!running) {
      return;
    }
    const packet = ensureAnnexBFrame(frame);
    try {
      player.decode(packet);
      setStreamState(`streaming (${mode})`, true);
    } catch (err) {
      log(`Broadway decode error: ${err.message}`);
    }
  };

  const frameLoop = () => {
    frameLoopId = 0;
    if (!running) {
      return;
    }
    let budget = decodeBudgetPerTick;
    while (budget > 0 && queue.length > 0) {
      const frame = queue.shift();
      decodeFrame(frame);
      budget -= 1;
    }
    if (queue.length > 0) {
      frameLoopId = requestAnimationFrame(frameLoop);
    }
  };

  const enqueueFrame = (frame) => {
    const isKeyframe = containsAnnexBNalType(frame, 5);
    if (waitingForKeyframe && !isKeyframe) {
      requestKeyframe();
      return;
    }
    if (isKeyframe) {
      waitingForKeyframe = false;
    }
    queue.push(frame);
    if (queue.length > maxQueueSize) {
      requestKeyframe();
      queue = [];
      waitingForKeyframe = true;
      if (isKeyframe) {
        queue.push(frame);
        waitingForKeyframe = false;
      }
    }
    if (!frameLoopId) {
      frameLoopId = requestAnimationFrame(frameLoop);
    }
  };

  return {
    async start() {
      mountSurface(canvas, mode);
      socket = openAppWebSocket(endpoint);
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState(`connected (${mode})`, true);
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, mode);
          return;
        }
        const frame = ensureAnnexBFrame(new Uint8Array(event.data));
        if (!frame.byteLength) {
          return;
        }
        enqueueFrame(frame);
      });
      socket.addEventListener('close', () => {
        setStreamState(`${mode} socket closed`, false);
      });
      socket.addEventListener('error', () => {
        setStreamState(`${mode} socket error`, false);
      });
    },
    async stop() {
      running = false;
      if (frameLoopId) {
        cancelAnimationFrame(frameLoopId);
        frameLoopId = 0;
      }
      queue = [];
      waitingForKeyframe = false;
      if (socket) {
        socket.close();
        socket = null;
      }
      if (player.worker && typeof player.worker.terminate === 'function') {
        player.worker.terminate();
      }
    },
  };
}

async function createMseH264Renderer(mode = 'h264-live-player', options = {}) {
  await ensureJmuxerLoaded();
  if (typeof window.JMuxer !== 'function') {
    throw new Error('JMuxer script is not loaded');
  }

  const requestedSource = typeof options.source === 'string' && options.source.trim()
    ? options.source.trim()
    : 'h264';
  const video = document.createElement('video');
  video.className = 'stream-media';
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;

  let socket = null;
  let muxer = null;
  let hasKeyframe = false;
  let waitingForKeyframe = true;
  let lastKeyframeRequestAt = 0;
  let lastFrameAt = 0;
  let lastResetAt = 0;

  const requestKeyframe = () => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return;
    }
    const now = Date.now();
    if (now - lastKeyframeRequestAt < H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS) {
      return;
    }
    lastKeyframeRequestAt = now;
    socket.send(JSON.stringify({type: 'request-keyframe'}));
  };

  const resetForLive = () => {
    const now = Date.now();
    if (now - lastResetAt < 1000) {
      return;
    }
    lastResetAt = now;
    hasKeyframe = false;
    waitingForKeyframe = true;
    try {
      muxer?.reset?.();
    } catch (err) {
      log(`${mode} reset warning: ${err.message}`);
    }
    requestKeyframe();
  };

  const keepVideoLive = () => {
    if (!video.buffered || video.buffered.length === 0 || !Number.isFinite(video.currentTime)) {
      return;
    }
    const end = video.buffered.end(video.buffered.length - 1);
    const delay = end - video.currentTime;
    if (delay > 0.35) {
      try {
        video.currentTime = Math.max(0, end - 0.05);
      } catch (_) {
        // Keep rendering even if this browser refuses a live seek for the current buffer.
      }
    }
    const playPromise = video.play?.();
    playPromise?.catch?.(() => {});
  };

  return {
    async start() {
      mountSurface(video, mode);
      muxer = new window.JMuxer({
        node: video,
        mode: 'video',
        fps: 30,
        flushingTime: 0,
        maxDelay: 120,
        clearBuffer: true,
        debug: false,
        onError: () => resetForLive(),
      });

      const endpoint = `${getEndpoint('h264Ws', '/ws/h264')}?source=${encodeURIComponent(requestedSource)}`;
      socket = openAppWebSocket(endpoint);
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState(`connected (${mode})`, true);
        requestKeyframe();
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, mode);
          return;
        }
        const packet = ensureAnnexBFrame(new Uint8Array(event.data));
        if (!packet.byteLength) {
          return;
        }
        const isKeyframe = containsAnnexBNalType(packet, 5);
        if (waitingForKeyframe && !isKeyframe) {
          requestKeyframe();
          return;
        }
        if (isKeyframe) {
          hasKeyframe = true;
          waitingForKeyframe = false;
        }
        if (!hasKeyframe) {
          requestKeyframe();
          return;
        }

        const now = performance.now();
        const duration = lastFrameAt ? Math.max(1, Math.min(80, Math.round(now - lastFrameAt))) : 33;
        lastFrameAt = now;
        try {
          muxer.feed({video: packet, duration});
          keepVideoLive();
          setStreamState(`streaming (${mode})`, true);
        } catch (err) {
          log(`${mode} decode warning: ${err.message}`);
          resetForLive();
        }
      });
      socket.addEventListener('close', () => {
        setStreamState(`${mode} socket closed`, false);
      });
      socket.addEventListener('error', () => {
        setStreamState(`${mode} socket error`, false);
      });
    },
    async stop() {
      if (socket) {
        socket.close();
        socket = null;
      }
      if (muxer && typeof muxer.destroy === 'function') {
        muxer.destroy();
      }
      muxer = null;
      hasKeyframe = false;
      waitingForKeyframe = true;
      video.removeAttribute('src');
    },
  };
}

function createTinyH264Renderer() {
  const canvas = document.createElement('canvas');
  canvas.className = 'stream-media';
  const context = canvas.getContext('2d', {alpha: false, desynchronized: true});
  if (!context) {
    throw new Error('Cannot create 2D context for tinyh264 renderer');
  }

  const renderStateId = 1;
  const endpoint = `${getEndpoint('h264Ws', '/ws/h264')}?source=h264`;
  let socket = null;
  let worker = null;
  let decoderReady = false;
  let imageData = null;

  const onWorkerMessage = (event) => {
    const payload = event.data || {};
    if (payload.type === 'decoderReady') {
      decoderReady = true;
      setStreamState('tinyh264 decoder ready', true);
      return;
    }
    if (payload.type !== 'pictureReady') {
      return;
    }
    const width = Number(payload.width) || 0;
    const height = Number(payload.height) || 0;
    if (!width || !height) {
      return;
    }
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      imageData = context.createImageData(width, height);
    }
    if (!imageData) {
      imageData = context.createImageData(width, height);
    }
    const yuv = new Uint8Array(payload.data);
    yuv420ToRgba(yuv, width, height, imageData.data);
    context.putImageData(imageData, 0, 0);
    setStreamState('streaming (tinyh264)', true);
  };

  return {
    async start() {
      mountSurface(canvas, 'tinyh264');
      worker = new Worker('/vendors/tinyh264/worker-entry.js', {type: 'module'});
      worker.addEventListener('message', onWorkerMessage);
      worker.addEventListener('error', (event) => {
        const detail = event?.message || 'unknown worker error';
        setStreamState(`tinyh264 worker error: ${detail}`, false);
      });

      socket = openAppWebSocket(endpoint);
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState('connected (tinyh264)', true);
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, 'tinyh264');
          return;
        }
        if (!decoderReady || !worker) {
          return;
        }
        const frame = ensureAnnexBFrame(new Uint8Array(event.data));
        const packet = frame.byteOffset === 0 && frame.byteLength === frame.buffer.byteLength
          ? frame
          : frame.slice();
        worker.postMessage({
          type: 'decode',
          data: packet.buffer,
          offset: 0,
          length: packet.byteLength,
          renderStateId,
        }, [packet.buffer]);
      });
      socket.addEventListener('close', () => {
        setStreamState('tinyh264 socket closed', false);
      });
      socket.addEventListener('error', () => {
        setStreamState('tinyh264 socket error', false);
      });
    },
    async stop() {
      if (socket) {
        socket.close();
        socket = null;
      }
      if (worker) {
        worker.postMessage({type: 'release', renderStateId});
        worker.removeEventListener('message', onWorkerMessage);
        worker.terminate();
        worker = null;
      }
      decoderReady = false;
      imageData = null;
    },
  };
}

function createWebCodecsRenderer(mode = 'webcodecs') {
  if (typeof window.VideoDecoder !== 'function' || typeof window.EncodedVideoChunk !== 'function') {
    throw new Error('WebCodecs is not supported in this browser');
  }

  const canvas = document.createElement('canvas');
  canvas.className = 'stream-media';
  const context = canvas.getContext('2d', {alpha: false, desynchronized: true});
  if (!context) {
    throw new Error('Cannot create 2D context for WebCodecs renderer');
  }

  const endpoint = `${getEndpoint('h264Ws', '/ws/h264')}?source=h264`;
  let socket = null;
  let decoder = null;
  let decoderConfigured = false;
  let decoderCodec = '';
  let timestampUs = 0;
  let lastPerfAt = 0;
  let waitingForKeyframe = false;
  let lastKeyframeRequestAt = 0;

  const requestKeyframe = () => {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return;
    }
    const now = Date.now();
    if (now - lastKeyframeRequestAt < H264_KEYFRAME_REQUEST_MIN_INTERVAL_MS) {
      return;
    }
    lastKeyframeRequestAt = now;
    socket.send(JSON.stringify({type: 'request-keyframe'}));
  };

  const ensureDecoderConfigured = (codec) => {
    if (!decoder) {
      return;
    }
    if (decoderConfigured && decoderCodec === codec) {
      return;
    }
    decoder.configure({
      codec,
      optimizeForLatency: true,
      hardwareAcceleration: 'prefer-hardware',
      avc: {format: 'annexb'},
    });
    decoderConfigured = true;
    decoderCodec = codec;
  };

  const decodeAccessUnit = (accessUnit) => {
    if (!decoder || !decoderConfigured || !accessUnit) {
      return;
    }
    const isKeyframe = Boolean(accessUnit.key);
    if (waitingForKeyframe && !isKeyframe) {
      requestKeyframe();
      return;
    }
    if (decoder.decodeQueueSize > 2) {
      requestKeyframe();
      decoder.reset();
      decoderConfigured = false;
      waitingForKeyframe = true;
      if (!isKeyframe) {
        return;
      }
      ensureDecoderConfigured(decoderCodec || 'avc1.42E01E');
      waitingForKeyframe = false;
    }
    if (isKeyframe) {
      waitingForKeyframe = false;
    }
    if (decoder.decodeQueueSize > 2) {
      return;
    }
    const data = accessUnit.packet
      ? accessUnit.packet
      : joinAnnexBNals(accessUnit.nals || []);
    if (!data || data.byteLength === 0) {
      return;
    }
    const type = isKeyframe ? 'key' : 'delta';
    const chunk = new EncodedVideoChunk({
      type,
      timestamp: timestampUs,
      data,
    });
    const now = performance.now();
    if (!lastPerfAt) {
      lastPerfAt = now;
    }
    const deltaUs = Math.max(1, Math.round((now - lastPerfAt) * 1000));
    lastPerfAt = now;
    timestampUs += deltaUs;
    decoder.decode(chunk);
  };

  const onFrame = (frame) => {
    try {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      context.drawImage(frame, 0, 0, canvas.width, canvas.height);
      setStreamState(`streaming (${mode})`, true);
    } finally {
      frame.close();
    }
  };

  const onDecoderError = (err) => {
    const message = err?.message || String(err);
    setStreamState(`${mode} decoder error`, false);
    log(`${mode} decode warning: ${message}`);
  };

  return {
    async start() {
      mountSurface(canvas, mode);
      decoder = new VideoDecoder({
        output: onFrame,
        error: onDecoderError,
      });

      socket = openAppWebSocket(endpoint);
      socket.binaryType = 'arraybuffer';
      socket.addEventListener('open', () => {
        setStreamState(`connected (${mode})`, true);
      });
      socket.addEventListener('message', (event) => {
        if (typeof event.data === 'string') {
          handleWsControl(event.data, mode);
          return;
        }
        const packet = ensureAnnexBFrame(new Uint8Array(event.data));
        if (!packet.byteLength) {
          return;
        }
        const codec = extractCodecStringFromAnnexBPacket(packet) || decoderCodec || 'avc1.42E01E';
        const accessUnit = {
          packet,
          key: containsAnnexBNalType(packet, 5),
        };
        try {
          ensureDecoderConfigured(codec);
          decodeAccessUnit(accessUnit);
        } catch (err) {
          const message = err?.message || String(err);
          log(`${mode} configure/decode error: ${message}`);
        }
      });
      socket.addEventListener('close', () => {
        setStreamState(`${mode} socket closed`, false);
      });
      socket.addEventListener('error', () => {
        setStreamState(`${mode} socket error`, false);
      });
    },
    async stop() {
      if (socket) {
        socket.close();
        socket = null;
      }
      if (decoder) {
        try {
          await decoder.flush();
        } catch (_) {
          // no-op
        }
        decoder.close();
      }
      decoder = null;
      decoderConfigured = false;
      decoderCodec = '';
      timestampUs = 0;
      lastPerfAt = 0;
      waitingForKeyframe = false;
    },
  };
}

function createWebRtcRenderer() {
  const video = document.createElement('video');
  video.className = 'stream-media';
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;

  let peer = null;

  return {
    async start() {
      mountSurface(video, 'webrtc-h264');
      const endpoint = getEndpoint('webrtcOffer', '/api/webrtc-offer');
      peer = new RTCPeerConnection();
      peer.addTransceiver('video', {direction: 'recvonly'});
      peer.addEventListener('track', (event) => {
        const stream = event.streams && event.streams[0] ? event.streams[0] : null;
        if (stream) {
          video.srcObject = stream;
          setStreamState('streaming (webrtc)', true);
        }
      });
      peer.addEventListener('connectionstatechange', () => {
        const status = peer.connectionState || 'unknown';
        const ok = ['connected', 'connecting'].includes(status);
        setStreamState(`webrtc ${status}`, ok);
      });

      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      await waitIceGatheringComplete(peer, 4000);
      const localDescription = peer.localDescription;
      if (!localDescription?.sdp) {
        throw new Error('Cannot build local WebRTC SDP offer');
      }

      const answer = await apiPost(endpoint, {sdp: localDescription.sdp});
      const answerSdp = String(answer?.answerSdp || '').trim();
      if (!answerSdp) {
        throw new Error('WebRTC answer SDP is empty');
      }
      await peer.setRemoteDescription({type: 'answer', sdp: answerSdp});
      setStreamState('webrtc connected', true);
    },
    async stop() {
      if (peer) {
        peer.close();
        peer = null;
      }
      video.srcObject = null;
    },
  };
}

function mountSurface(surfaceElement, mode = '') {
  el.streamHost.innerHTML = '';
  surfaceElement.dataset.streamMode = String(mode || '').toLowerCase();
  surfaceElement.classList.toggle('stream-media-edge-trim', shouldTrimSurfaceEdges(mode));
  el.streamHost.appendChild(surfaceElement);
  state.activeSurface = surfaceElement;
  fitActiveMjpegSurface();
}

function shouldTrimSurfaceEdges(mode) {
  return Boolean(String(mode || '').trim());
}

function fitMjpegSurfaceToViewer(surfaceElement) {
  if (!(surfaceElement instanceof HTMLImageElement)) {
    return;
  }
  const mode = String(surfaceElement.dataset.streamMode || '').toLowerCase();
  if (!FRAME_IMAGE_VIEW_MODES.includes(mode)) {
    return;
  }
  const srcWidth = Number(surfaceElement.naturalWidth) || 0;
  const srcHeight = Number(surfaceElement.naturalHeight) || 0;
  if (srcWidth > 0 && srcHeight > 0) {
    applyViewerAspect(srcWidth, srcHeight);
  }
  surfaceElement.style.removeProperty('width');
  surfaceElement.style.removeProperty('height');
}

function fitActiveMjpegSurface() {
  if (!(state.activeSurface instanceof HTMLImageElement)) {
    return;
  }
  fitMjpegSurfaceToViewer(state.activeSurface);
}

function applyViewerAspect(width, height) {
  const w = Number(width);
  const h = Number(height);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) {
    return;
  }
  const aspect = w / h;
  if (!Number.isFinite(aspect) || aspect <= 0) {
    return;
  }
  if (Math.abs(state.viewerAspect - aspect) < 0.000001) {
    return;
  }
  state.viewerAspect = aspect;
  el.viewer.style.setProperty('--device-aspect', String(aspect));
}

function isPointArraySwipeEnabled() {
  const mode = getSelectedControlMode();
  return mode === CONTROL_MODE_SOCKET_REALTIME;
}

function shouldBeginRealtimeEdgeTouch(point) {
  return shouldUseRealtimeTouchStream() && isBottomEdgeStart(point);
}

function isRealtimeBottomEdgeSwipeUp(start, end, distance) {
  if (!shouldUseRealtimeTouchStream()) {
    return false;
  }
  const size = getDisplayedDeviceCoordinateSize();
  const height = Number(size.height) || 0;
  if (height <= 0) {
    return false;
  }
  const minVerticalDistance = Math.max(80, height * REALTIME_EDGE_TOUCH_MIN_VERTICAL_DISTANCE_RATIO);
  return distance >= minVerticalDistance && isBottomEdgeSwipeUp(start, end, minVerticalDistance);
}

function isBottomEdgeStart(point) {
  if (!point) {
    return false;
  }
  const size = getDisplayedDeviceCoordinateSize();
  const height = Number(size.height) || 0;
  if (height <= 0) {
    return false;
  }
  const bottomInset = Math.max(REALTIME_EDGE_TOUCH_BOTTOM_INSET_PX, height * 0.04);
  return point.y >= height - bottomInset;
}

function isBottomEdgeSwipeUp(start, point, minVerticalDistance) {
  if (!start || !point) {
    return false;
  }
  const size = getDisplayedDeviceCoordinateSize();
  const height = Number(size.height) || 0;
  if (height <= 0) {
    return false;
  }
  const verticalDistance = start.y - point.y;
  const horizontalDistance = Math.abs(point.x - start.x);
  return (
    isBottomEdgeStart(start) &&
    verticalDistance >= minVerticalDistance &&
    verticalDistance >= horizontalDistance * 1.2
  );
}

function realtimeEdgeTouchStartPoint(point) {
  const size = getDisplayedDeviceCoordinateSize();
  const height = Number(size.height) || 0;
  if (!isBottomEdgeStart(point) || height <= 1) {
    return point;
  }
  return {...point, y: Math.max(0, Math.round(height - 1))};
}

function realtimeEdgeTouchEndPoint(start, end, distance) {
  if (!isRealtimeBottomEdgeSwipeUp(start, end, distance)) {
    return end;
  }
  const size = getDisplayedDeviceCoordinateSize();
  const height = Number(size.height) || 0;
  if (height <= 0) {
    return end;
  }
  const targetY = Math.round(Math.max(24, height * REALTIME_EDGE_TOUCH_TOP_TARGET_RATIO));
  if (end.y <= targetY) {
    return end;
  }
  return {...end, y: targetY};
}

async function applySelectedControlMode(force = false) {
  const mode = normalizeControlModeId(el.controlModeSelect.value || state.selectedControlMode)
    || CONTROL_MODE_SOCKET_REALTIME;
  const modeInfo = state.controlModeMap.get(mode);
  if (modeInfo && !modeInfo.enabled) {
    throw new Error(`Control mode "${mode}" is disabled by server config`);
  }
  if (!force && state.selectedControlMode === mode) {
    return;
  }

  state.selectedControlMode = mode;
  persistRequestedControlMode(mode);
  setControlModeLabel(mode);
  if (!isSocketControlMode(mode)) {
    closeRealtimeControlClient();
    setControlState(controlModeHttpState(mode));
    return;
  }
  const client = getRealtimeControlClient(mode);
  try {
    await client.connect();
    setControlState(controlModeSocketReadyState(mode));
  } catch (err) {
    log(`Realtime control connect warning: ${err.message}`);
    setControlState(controlModeSocketUnavailableState(mode));
  }
}

function getSelectedControlMode() {
  return normalizeControlModeId(el.controlModeSelect?.value || state.selectedControlMode)
    || CONTROL_MODE_SOCKET_REALTIME;
}

function shouldUseRealtimeTouchStream() {
  return getSelectedControlMode() === CONTROL_MODE_SOCKET_REALTIME
    && state.controlStream?.upstream?.is_trollstore === true;
}

async function sendHomeControl() {
  return sendControlCommand(
    {type: 'home'},
    () => apiPost('/api/home'),
  );
}

async function sendTapGesture(point, pointerId = 1) {
  if (shouldUseRealtimeTouchStream()) {
    return sendRealtimeTapGesture(point, pointerId);
  }
  return sendControlCommand(
    {type: 'tap', x: point.x, y: point.y},
    () => apiPost('/api/tap', point),
  );
}

async function sendRealtimeTapGesture(point, pointerId = 1) {
  const previousPointerId = state.liveTouchPointerId;
  const previousLastPoint = state.liveTouchLastPoint;
  const previousTransport = state.liveTouchTransport;
  const tapPointerId = pointerId || 1;
  state.liveTouchPointerId = tapPointerId;
  state.liveTouchLastPoint = point;
  state.liveTouchTransport = '';
  try {
    const down = await sendRealtimeTouchDown(point, tapPointerId);
    const up = await sendRealtimeTouchUp(point, tapPointerId);
    return {
      ok: true,
      command: '/ws/realtime-control',
      transport: 'realtime',
      result: {down, up},
    };
  } catch (err) {
    await sendRealtimeTouchCancel().catch(() => {});
    throw err;
  } finally {
    state.liveTouchPointerId = previousPointerId;
    state.liveTouchLastPoint = previousLastPoint;
    state.liveTouchTransport = previousTransport;
  }
}

async function sendPointArrayGesture(pointArray) {
  return sendControlCommand(
    {type: 'pointArray', pointArray},
    () => apiPost('/api/point-array', {pointArray}),
  );
}

function sendSwipeGesture(start, end, duration = SWIPE_MIN_DURATION_SECONDS) {
  const command = {
    type: 'swipe',
    fromX: start.x,
    fromY: start.y,
    toX: end.x,
    toY: end.y,
    duration,
  };
  return sendControlCommand(command, () => apiPost('/api/swipe', {
    fromX: start.x,
    fromY: start.y,
    toX: end.x,
    toY: end.y,
    duration,
  }));
}

async function sendRecordedGestureFallback(start, end, distance, event) {
  if (distance < TAP_THRESHOLD_PX) {
    const data = await sendTapGesture(end, event.pointerId);
    flashPoint(event.clientX, event.clientY);
    logData('TAP', {point: end, response: data});
  } else if (isPointArraySwipeEnabled()) {
    const pointArray = buildPointArrayPayload(state.dragSamples);
    try {
      const data = await sendPointArrayGesture(pointArray);
      logData('POINT_ARRAY', {
        samples: state.dragSamples.length,
        pointArrayLength: pointArray.length,
        response: data,
      });
    } catch (err) {
      log(`POINT_ARRAY fallback to SWIPE: ${err.message}`);
      const fallback = await sendSwipeGesture(start, end, estimateSwipeDurationSeconds(state.dragSamples));
      logData('SWIPE_FALLBACK', {
        from: start,
        to: end,
        reason: err.message,
        response: fallback,
      });
    }
  } else {
    const data = await sendSwipeGesture(start, end, estimateSwipeDurationSeconds(state.dragSamples));
    logData('SWIPE', {from: start, to: end, response: data});
  }
}

function nextLiveTouchSequence() {
  const sequence = state.liveTouchSequence;
  state.liveTouchSequence += 1;
  return sequence;
}

function realtimeTouchPayload(type, point, pointerId, options = {}) {
  const payload = {
    type,
    x: point?.x ?? state.liveTouchLastPoint?.x ?? 0,
    y: point?.y ?? state.liveTouchLastPoint?.y ?? 0,
    pointerId: pointerId || state.liveTouchPointerId || 1,
    sequence: nextLiveTouchSequence(),
    timestamp: Date.now(),
    ack: options.ack !== false,
  };
  if (REALTIME_TOUCH_DEBUG) {
    console.log('[RT INPUT]', {
      stage: 'client-build',
      type: payload.type,
      sequence: payload.sequence,
      pointerId: payload.pointerId,
      x: payload.x,
      y: payload.y,
      clientTs: payload.timestamp,
      ack: payload.ack,
    });
  }
  return payload;
}

function beginRealtimeTouchStream(pointerId) {
  if (state.liveTouchActive || state.liveTouchFailed || !state.dragStart) {
    return false;
  }
  const downPoint = realtimeEdgeTouchStartPoint(state.dragStart);
  state.liveTouchActive = true;
  state.liveTouchBroken = false;
  state.liveTouchPointerId = pointerId || 1;
  state.liveTouchLastPoint = downPoint;
  state.liveTouchPendingMove = null;
  state.liveTouchLastPointerMoveAt = Date.now();
  state.liveTouchTransport = '';
  state.liveTouchStartPromise = sendRealtimeTouchDown(downPoint, state.liveTouchPointerId).catch((err) => {
      state.liveTouchActive = false;
      state.liveTouchFailed = true;
      stopRealtimeTouchHoldSampler();
      log(`TOUCH_DOWN failed: ${err.message}`, true);
    });
  startRealtimeTouchHoldSampler();
  return true;
}

function sendRealtimeTouchDown(point, pointerId) {
  const command = realtimeTouchPayload('touchDown', point, pointerId);
  return sendControlCommand(
    command,
    () => apiPost('/api/touch-down', command),
    {allowHttpFallback: false},
  ).then((data) => {
    state.liveTouchTransport = data?.transport || (data?.command === '/ws/realtime-control' ? 'realtime' : 'http');
    return data;
  });
}

function sendRealtimeTouchMove(point) {
  const command = realtimeTouchPayload('touchMove', point, state.liveTouchPointerId, {ack: false});
  return sendControlCommand(
    command,
    () => apiPost('/api/touch-move', command),
    {expectResponse: false, allowHttpFallback: false},
  );
}

function sendRealtimeTouchUp(point, pointerId) {
  const command = realtimeTouchPayload('touchUp', point, pointerId);
  return sendControlCommand(
    command,
    () => apiPost('/api/touch-up', command),
    {allowHttpFallback: false},
  );
}

function sendRealtimeTouchCancel() {
  const point = state.liveTouchLastPoint || state.dragLastPoint || state.dragStart || {x: 0, y: 0};
  const command = realtimeTouchPayload('touchCancel', point, state.liveTouchPointerId);
  return sendControlCommand(
    command,
    () => apiPost('/api/touch-cancel', command),
    {allowHttpFallback: false},
  );
}

function startRealtimeTouchHoldSampler() {
  stopRealtimeTouchHoldSampler();
  state.liveTouchHoldTimer = window.setInterval(() => {
    if (!state.dragging || !state.liveTouchActive || state.liveTouchFailed || state.liveTouchBroken) {
      stopRealtimeTouchHoldSampler();
      return;
    }
    const point = state.liveTouchLastPoint || state.dragLastPoint || state.dragStart;
    if (!point) {
      return;
    }
    if (Date.now() - state.liveTouchLastPointerMoveAt < REALTIME_TOUCH_HOLD_IDLE_MS) {
      return;
    }
    queueRealtimeTouchMove(point, {hold: true});
  }, REALTIME_TOUCH_HOLD_SAMPLE_INTERVAL_MS);
}

function stopRealtimeTouchHoldSampler() {
  if (!state.liveTouchHoldTimer) {
    return;
  }
  window.clearInterval(state.liveTouchHoldTimer);
  state.liveTouchHoldTimer = 0;
}

function queueRealtimeTouchMove(point, options = {}) {
  if (!state.liveTouchActive || !point) {
    return;
  }
  state.liveTouchPendingMove = point;
  if (REALTIME_TOUCH_DEBUG) {
    console.log('[RT INPUT]', {
      stage: 'client-queue',
      type: 'move',
      x: point.x,
      y: point.y,
      pending: 1,
      hold: Boolean(options.hold),
    });
  }
  if (state.liveTouchMoveTimer) {
    return;
  }
  state.liveTouchMoveTimer = window.setTimeout(() => {
    state.liveTouchMoveTimer = 0;
    flushRealtimeTouchMove().catch((err) => {
      state.liveTouchBroken = true;
      log(`TOUCH_MOVE failed: ${err.message}`, true);
      cancelRealtimeTouchStream().catch(() => {});
    });
  }, REALTIME_TOUCH_MOVE_INTERVAL_MS);
}

async function flushRealtimeTouchMove() {
  if (state.liveTouchMoveTimer) {
    window.clearTimeout(state.liveTouchMoveTimer);
    state.liveTouchMoveTimer = 0;
  }
  const point = state.liveTouchPendingMove;
  state.liveTouchPendingMove = null;
  if (!state.liveTouchActive || !point) {
    return null;
  }
  if (state.liveTouchStartPromise) {
    await state.liveTouchStartPromise;
  }
  if (!state.liveTouchActive || state.liveTouchFailed || state.liveTouchBroken) {
    return null;
  }
  try {
    const result = await sendRealtimeTouchMove(point);
    if (REALTIME_TOUCH_DEBUG) {
      console.log('[RT INPUT]', {
        stage: 'client-send',
        type: 'move',
        x: point.x,
        y: point.y,
        clientTs: Date.now(),
        transport: result?.transport || 'realtime',
      });
    }
    return result;
  } catch (err) {
    state.liveTouchBroken = true;
    throw err;
  }
}

async function cancelRealtimeTouchStream() {
  if (state.liveTouchMoveTimer) {
    window.clearTimeout(state.liveTouchMoveTimer);
    state.liveTouchMoveTimer = 0;
  }
  stopRealtimeTouchHoldSampler();
  state.liveTouchPendingMove = null;
  try {
    if (state.liveTouchStartPromise) {
      await state.liveTouchStartPromise;
    }
    if (state.liveTouchActive) {
      await sendRealtimeTouchCancel();
    }
  } finally {
    state.liveTouchActive = false;
    state.liveTouchFailed = false;
    state.liveTouchBroken = false;
    state.liveTouchPointerId = 0;
    state.liveTouchLastPoint = null;
    state.liveTouchLastPointerMoveAt = 0;
    state.liveTouchStartPromise = null;
  }
}

async function sendControlCommand(command, httpFallback, options = {}) {
  const mode = getSelectedControlMode();
  const pinnedTransport = isLiveTouchCommand(command) ? state.liveTouchTransport : '';
  const allowHttpFallback = options.allowHttpFallback !== false;
  if (!shouldSendCommandViaSocket(command, mode, pinnedTransport)) {
    if (!allowHttpFallback) {
      const err = new Error('Realtime touch stream is not available on this build');
      err.sent = false;
      throw err;
    }
    setControlState(controlModeHttpState(mode));
    const result = await httpFallback();
    return result && typeof result === 'object'
      ? {...result, transport: result.transport || 'http'}
      : result;
  }

  const client = getRealtimeControlClient(mode);
  const endpoint = getControlWebSocketEndpoint(mode);
  try {
    const result = await client.send(command, {
      timeoutMs: CONTROL_COMMAND_TIMEOUT_MS,
      waitForOpenMs: CONTROL_COMMAND_TIMEOUT_MS,
      expectResponse: options.expectResponse !== false,
    });
    if (options.expectResponse !== false) {
      setControlState(controlModeSocketReadyState(mode));
    }
    return {
      ok: true,
      command: endpoint,
      transport: controlModeTransport(mode),
      result,
    };
  } catch (err) {
    if (err?.sent) {
      throw err;
    }
    if (pinnedTransport === 'realtime') {
      throw err;
    }
    if (!allowHttpFallback) {
      throw err;
    }
    log(`Realtime control fallback to HTTP: ${err.message}`);
    setControlState(controlModeHttpState(mode, true));
    const result = await httpFallback();
    return result && typeof result === 'object'
      ? {...result, transport: result.transport || 'http'}
      : result;
  }
}

function isLiveTouchCommand(command) {
  const type = getControlCommandType(command);
  return (
    type === 'touchdown' ||
    type === 'touchmove' ||
    type === 'touchup' ||
    type === 'touchcancel' ||
    type === 'down' ||
    type === 'move' ||
    type === 'up' ||
    type === 'cancel'
  );
}

function isMeshGestureCommand(command) {
  const type = getControlCommandType(command);
  return type === 'pointarray' || type === 'gesture' || type === 'swipe';
}

function getControlCommandType(command) {
  return String(command?.type || '').trim().toLowerCase().replace(/[-_]/g, '');
}

function shouldSendCommandViaSocket(command, mode, pinnedTransport = '') {
  if (pinnedTransport === 'http') {
    return false;
  }
  const normalizedMode = normalizeControlModeId(mode);
  if (!isSocketControlMode(normalizedMode)) {
    return false;
  }
  if (normalizedMode === CONTROL_MODE_SOCKET_SWIPE) {
    return isMeshGestureCommand(command);
  }
  if (isLiveTouchCommand(command)) {
    return shouldUseRealtimeTouchStream() || pinnedTransport === 'realtime';
  }
  if (getControlCommandType(command) === 'swipe') {
    return false;
  }
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return true;
  }
  return false;
}

function isSocketControlMode(mode) {
  return CONTROL_SOCKET_MODES.has(normalizeControlModeId(mode));
}

function controlModeSocketUnavailableState(mode) {
  const normalizedMode = normalizeControlModeId(mode);
  if (normalizedMode === CONTROL_MODE_SOCKET_SWIPE) {
    return 'mesh swipe socket unavailable';
  }
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return 'realtime socket unavailable';
  }
  return 'http fallback';
}

function controlModeSocketReadyState(mode) {
  const normalizedMode = normalizeControlModeId(mode);
  if (normalizedMode === CONTROL_MODE_SOCKET_SWIPE) {
    return 'mesh swipe socket ready';
  }
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return 'realtime socket ready';
  }
  return 'socket ready';
}

function controlModeHttpState(mode, fallback = false) {
  const normalizedMode = normalizeControlModeId(mode);
  const suffix = fallback ? ' fallback' : '';
  if (normalizedMode === CONTROL_MODE_SOCKET_SWIPE) {
    return `http swipe${suffix}`;
  }
  return `http realtime${suffix}`;
}

function controlModeTransport(mode) {
  return normalizeControlModeId(mode) === CONTROL_MODE_SOCKET_SWIPE ? 'mesh' : 'realtime';
}

function getControlWebSocketEndpoint(mode = getSelectedControlMode()) {
  const normalizedMode = normalizeControlModeId(mode);
  if (normalizedMode === CONTROL_MODE_SOCKET_SWIPE) {
    return getEndpoint('realtimeControlMeshWs', '/ws/realtime-control-mesh');
  }
  if (normalizedMode === CONTROL_MODE_SOCKET_REALTIME) {
    return getEndpoint('realtimeControlWs', '/ws/realtime-control');
  }
  return getEndpoint('realtimeControlWs', '/ws/realtime-control');
}

function getRealtimeControlClient(mode = getSelectedControlMode()) {
  const endpoint = getControlWebSocketEndpoint(mode);
  if (!state.controlClient || state.controlClientEndpoint !== endpoint) {
    closeRealtimeControlClient();
    state.controlClient = createRealtimeControlClient(endpoint);
    state.controlClientEndpoint = endpoint;
  }
  return state.controlClient;
}

function closeRealtimeControlClient() {
  if (!state.controlClient) {
    return;
  }
  state.controlClient.close();
  state.controlClient = null;
  state.controlClientEndpoint = '';
}

function createRealtimeControlClient(endpoint) {
  let socket = null;
  let connectPromise = null;
  let reconnectTimer = 0;
  let seq = 1;
  let ready = false;
  let shouldReconnect = true;
  const pending = new Map();

  const cleanupPending = (err, sent = true) => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      if (err && typeof err === 'object') {
        err.sent = sent;
      }
      entry.reject(err);
    }
    pending.clear();
  };

  const scheduleReconnect = () => {
    if (!shouldReconnect || reconnectTimer || !isSocketControlMode(getSelectedControlMode())) {
      return;
    }
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = 0;
      connect().catch(() => {});
    }, CONTROL_SOCKET_RECONNECT_MS);
  };

  const onOpen = () => {
    setControlState('socket connecting');
  };

  const onMessage = (event) => {
    if (typeof event.data !== 'string') {
      return;
    }
    let payload;
    try {
      payload = JSON.parse(event.data);
    } catch (_) {
      return;
    }

    if (payload.type === 'ready') {
      ready = true;
      if (typeof payload.is_trollstore === 'boolean') {
        const stream = state.controlStream || (state.controlStream = {});
        const upstream = stream.upstream || (stream.upstream = {});
        upstream.is_trollstore = payload.is_trollstore;
      }
      setControlState('socket ready');
      return;
    }
    if (payload.type === 'connecting') {
      setControlState('socket connecting');
      return;
    }
    if (payload.type === 'error') {
      const message = payload.message || payload.error || 'Realtime control error';
      setControlState('socket error');
      log(message, true);
      return;
    }

    const requestId = payload.id == null ? '' : String(payload.id);
    const entry = pending.get(requestId);
    if (!entry) {
      return;
    }
    pending.delete(requestId);
    clearTimeout(entry.timer);
    if (payload.ok === false) {
      const err = new Error(payload.error || 'Realtime control command failed');
      err.sent = true;
      entry.reject(err);
    } else {
      entry.resolve(payload);
    }
  };

  const onClose = () => {
    ready = false;
    connectPromise = null;
    socket = null;
    cleanupPending(new Error('Realtime control socket closed'), true);
    setControlState('socket closed');
    scheduleReconnect();
  };

  const onError = () => {
    setControlState('socket error');
  };

  const connect = () => {
    if (socket && socket.readyState === WebSocket.OPEN && !ready) {
      try {
        socket.close();
      } catch (_) {
        // no-op
      }
      socket = null;
    }
    if (ready && socket?.readyState === WebSocket.OPEN) {
      return Promise.resolve();
    }
    if (connectPromise) {
      return connectPromise;
    }
    if (socket && socket.readyState === WebSocket.CONNECTING) {
      connectPromise = new Promise((resolve, reject) => {
        const cleanup = () => {
          socket?.removeEventListener('message', onReady);
          socket?.removeEventListener('close', onFail);
          socket?.removeEventListener('error', onFail);
          connectPromise = null;
        };
        const onReady = (event) => {
          if (typeof event.data !== 'string') {
            return;
          }
          try {
            if (JSON.parse(event.data)?.type !== 'ready') {
              return;
            }
          } catch (_) {
            return;
          }
          cleanup();
          resolve();
        };
        const onFail = () => {
          cleanup();
          const err = new Error('Realtime control socket is not ready');
          err.transportUnavailable = true;
          err.sent = false;
          reject(err);
        };
        socket.addEventListener('message', onReady);
        socket.addEventListener('close', onFail, {once: true});
        socket.addEventListener('error', onFail, {once: true});
      });
      return connectPromise;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = 0;
    ready = false;
    setControlState('socket connecting');
    socket = openAppWebSocket(endpoint);
    socket.addEventListener('open', onOpen);
    socket.addEventListener('message', onMessage);
    socket.addEventListener('close', onClose);
    socket.addEventListener('error', onError);

    connectPromise = new Promise((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        cleanup();
        try {
          socket?.close();
        } catch (_) {
          // no-op
        }
        const err = new Error('Realtime control socket open timed out');
        err.transportUnavailable = true;
        err.sent = false;
        reject(err);
      }, CONTROL_COMMAND_TIMEOUT_MS);
      const cleanup = () => {
        window.clearTimeout(timeout);
        socket?.removeEventListener('message', onReady);
        socket?.removeEventListener('close', onFail);
        socket?.removeEventListener('error', onFail);
        connectPromise = null;
      };
      const onReady = (event) => {
        if (typeof event.data !== 'string') {
          return;
        }
        let payload;
        try {
          payload = JSON.parse(event.data);
        } catch (_) {
          return;
        }
        if (payload.type !== 'ready') {
          return;
        }
        cleanup();
        resolve();
      };
      const onFail = () => {
        cleanup();
        const err = new Error('Realtime control socket is not ready');
        err.transportUnavailable = true;
        err.sent = false;
        reject(err);
      };
      socket.addEventListener('message', onReady);
      socket.addEventListener('close', onFail, {once: true});
      socket.addEventListener('error', onFail, {once: true});
    });
    return connectPromise;
  };

  const waitForReady = (waitForOpenMs) => {
    if (ready && socket?.readyState === WebSocket.OPEN) {
      return Promise.resolve();
    }
    const pendingConnect = connect();
    if (!waitForOpenMs || waitForOpenMs >= CONTROL_COMMAND_TIMEOUT_MS) {
      return pendingConnect;
    }
    return Promise.race([
      pendingConnect,
      new Promise((_, reject) => {
        window.setTimeout(
          () => {
            const err = new Error('Realtime control socket is not ready');
            err.transportUnavailable = true;
            err.sent = false;
            reject(err);
          },
          waitForOpenMs,
        );
      }),
    ]);
  };

  return {
    connect,
    close() {
      shouldReconnect = false;
      clearTimeout(reconnectTimer);
      reconnectTimer = 0;
      ready = false;
      cleanupPending(new Error('Realtime control socket closed'));
      if (socket) {
        socket.close();
        socket = null;
      }
      connectPromise = null;
    },
    async send(command, options = {}) {
      const timeoutMs = Math.max(250, options.timeoutMs || CONTROL_COMMAND_TIMEOUT_MS);
      const expectResponse = options.expectResponse !== false;
      if (expectResponse) {
        await waitForReady(options.waitForOpenMs);
      }
      if (!socket || socket.readyState !== WebSocket.OPEN || !ready) {
        const err = new Error('Realtime control socket is not ready');
        err.transportUnavailable = true;
        err.sent = false;
        throw err;
      }

      const id = expectResponse ? seq++ : null;
      const payload = expectResponse ? {...command, id} : {...command};
      if (!expectResponse) {
        try {
          socket.send(JSON.stringify(payload));
          return {ok: true, sent: true};
        } catch (err) {
          err.sent = false;
          err.transportUnavailable = true;
          throw err;
        }
      }

      return new Promise((resolve, reject) => {
        const requestId = String(id);
        const timer = window.setTimeout(() => {
          pending.delete(requestId);
          const err = new Error('Realtime control command timed out');
          err.sent = true;
          reject(err);
        }, timeoutMs);
        pending.set(requestId, {resolve, reject, timer});
        try {
          socket.send(JSON.stringify(payload));
        } catch (err) {
          clearTimeout(timer);
          pending.delete(requestId);
          err.sent = false;
          err.transportUnavailable = true;
          reject(err);
        }
      });
    },
  };
}

function setControlState(text) {
  if (!el.controlStateLabel) {
    return;
  }
  el.controlStateLabel.textContent = text || '-';
}

function getPointArraySampleMs() {
  if (!el.pointArraySampleMsInput) {
    return POINT_ARRAY_DEFAULT_SAMPLE_MS;
  }
  const normalized = normalizeSettingValue(
    Number(el.pointArraySampleMsInput.value),
    1,
    200,
    POINT_ARRAY_DEFAULT_SAMPLE_MS,
  );
  el.pointArraySampleMsInput.value = String(normalized);
  return normalized;
}

function resetDragTracking() {
  state.dragLastPoint = null;
  state.dragDistance = 0;
  state.dragSamples = [];
}

function recordDragSample(point, force) {
  if (!point) {
    return;
  }
  const now = Date.now();
  const sample = {x: point.x, y: point.y, t: now};
  if (!Array.isArray(state.dragSamples) || state.dragSamples.length === 0) {
    state.dragSamples = [sample];
    return;
  }
  const last = state.dragSamples[state.dragSamples.length - 1];
  if (last.x === sample.x && last.y === sample.y) {
    last.t = sample.t;
    return;
  }
  const elapsed = sample.t - last.t;
  const distance = Math.hypot(sample.x - last.x, sample.y - last.y);
  if (!force && elapsed < getPointArraySampleMs() && distance < POINT_ARRAY_SAMPLE_DISTANCE_PX) {
    return;
  }
  state.dragSamples.push(sample);
}

function buildPointArrayPayload(samples) {
  if (!Array.isArray(samples) || samples.length < 2) {
    throw new Error('Not enough drag points to build pointArray payload');
  }
  const first = samples[0];
  const baseTime = samples[1]?.t ?? first.t;
  const pointArray = [[first.x, first.y]];
  for (let i = 1; i < samples.length; i += 1) {
    const p = samples[i];
    const dt = POINT_ARRAY_START_MOVE_DELAY_SECONDS + Math.max(0, (p.t - baseTime) / 1000);
    pointArray.push([p.x, p.y, Number(dt.toFixed(3))]);
  }
  return pointArray;
}

function estimateSwipeDurationSeconds(samples) {
  if (!Array.isArray(samples) || samples.length < 2) {
    return SWIPE_MIN_DURATION_SECONDS;
  }
  const baseTime = samples[1]?.t ?? samples[0].t;
  const last = samples[samples.length - 1];
  const duration = POINT_ARRAY_START_MOVE_DELAY_SECONDS + Math.max(0, (last.t - baseTime) / 1000);
  return Math.min(SWIPE_MAX_DURATION_SECONDS, Math.max(SWIPE_MIN_DURATION_SECONDS, Number(duration.toFixed(3))));
}

function getEndpoint(key, fallback) {
  const endpoint =
    state.controlStream?.endpoints?.[key] ||
    state.streamConfig?.endpoints?.[key];
  return typeof endpoint === 'string' && endpoint.trim() ? endpoint : fallback;
}

function openAppWebSocket(pathnameWithQuery) {
  const wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return new WebSocket(`${wsProtocol}//${location.host}${appendAuthQuery(pathnameWithQuery)}`);
}

function appendQueryParam(pathnameWithQuery, name, value) {
  const separator = String(pathnameWithQuery).includes('?') ? '&' : '?';
  return `${pathnameWithQuery}${separator}${encodeURIComponent(name)}=${encodeURIComponent(String(value))}`;
}

function appendAuthQuery(pathnameWithQuery) {
  if (!APP_AUTH_TOKEN) {
    return pathnameWithQuery;
  }
  return appendQueryParam(pathnameWithQuery, 'auth', APP_AUTH_TOKEN);
}

function getCurrentMjpegFps() {
  return normalizeSettingValue(Number(el.fpsInput?.value), 1, 60, 30);
}

function handleWsControl(text, mode) {
  let payload;
  try {
    payload = JSON.parse(text);
  } catch (_) {
    return;
  }
  if (payload.type === 'log') {
    const message = payload.message || '';
    if (message) {
      log(message, payload.level === 'error');
    }
    return;
  }
  if (payload.type === 'error') {
    setStreamState(`${mode} error`, false);
    log(`${mode} websocket error: ${payload.message || 'unknown'}`, true);
    return;
  }
  if (payload.type === 'ready') {
    setStreamState(`connected (${mode})`, true);
  }
}

async function ensureBroadwayLoaded() {
  await loadScriptOnce('/vendors/broadway/Decoder.js');
  await loadScriptOnce('/vendors/broadway/YUVCanvas.js');
  await loadScriptOnce('/vendors/broadway/Player.js');
}

async function ensureJmuxerLoaded() {
  await loadScriptOnce('/vendors/jmuxer/jmuxer.min.js');
}

async function loadScriptOnce(src) {
  if (SCRIPT_CACHE.has(src)) {
    return SCRIPT_CACHE.get(src);
  }
  const promise = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`Cannot load script: ${src}`));
    document.head.appendChild(script);
  });
  SCRIPT_CACHE.set(src, promise);
  return promise;
}

function ensureAnnexBFrame(frame) {
  if (!frame || frame.byteLength === 0) {
    return new Uint8Array(0);
  }
  const hasStartCode3 = frame.byteLength >= 3
    && frame[0] === 0x00
    && frame[1] === 0x00
    && frame[2] === 0x01;
  const hasStartCode4 = frame.byteLength >= 4
    && frame[0] === 0x00
    && frame[1] === 0x00
    && frame[2] === 0x00
    && frame[3] === 0x01;
  if (hasStartCode3 || hasStartCode4) {
    return frame;
  }
  const out = new Uint8Array(frame.byteLength + 4);
  out[0] = 0x00;
  out[1] = 0x00;
  out[2] = 0x00;
  out[3] = 0x01;
  out.set(frame, 4);
  return out;
}

function createH264AccessUnitAssembler() {
  const parser = createAnnexBNaluStreamParser();
  let pendingNals = [];
  let hasVcl = false;
  let keyFrame = false;

  const flushPending = () => {
    if (!hasVcl || pendingNals.length === 0) {
      pendingNals = [];
      hasVcl = false;
      keyFrame = false;
      return null;
    }
    const output = {
      nals: pendingNals,
      key: keyFrame,
    };
    pendingNals = [];
    hasVcl = false;
    keyFrame = false;
    return output;
  };

  const onNal = (nal, output) => {
    const type = nalTypeOf(nal);
    if (!type) {
      return;
    }
    const isVcl = type === 1 || type === 5;
    const startsNewPicture = isVcl ? isFirstSliceNal(nal) : false;

    if (type === 9 && hasVcl) {
      const accessUnit = flushPending();
      if (accessUnit) {
        output.push(accessUnit);
      }
      return;
    }

    if (isVcl && hasVcl && startsNewPicture) {
      const accessUnit = flushPending();
      if (accessUnit) {
        output.push(accessUnit);
      }
    } else if (!isVcl && hasVcl && (type === 7 || type === 8)) {
      const accessUnit = flushPending();
      if (accessUnit) {
        output.push(accessUnit);
      }
    }

    pendingNals.push(nal);
    if (isVcl) {
      hasVcl = true;
      if (type === 5) {
        keyFrame = true;
      }
    }
  };

  return {
    push(chunk) {
      const output = [];
      const nals = parser.push(chunk);
      for (const nal of nals) {
        onNal(nal, output);
      }
      return output;
    },
    flush() {
      const output = [];
      const nals = parser.flush();
      for (const nal of nals) {
        onNal(nal, output);
      }
      const final = flushPending();
      if (final) {
        output.push(final);
      }
      return output;
    },
  };
}

function createAnnexBNaluStreamParser() {
  let carry = new Uint8Array(0);
  return {
    push(chunk) {
      if (!chunk || chunk.byteLength === 0) {
        return [];
      }
      carry = concatUint8(carry, ensureAnnexBFrame(chunk));
      const extracted = splitAnnexBNals(carry, false);
      carry = extracted.rest;
      return extracted.nals;
    },
    flush() {
      const extracted = splitAnnexBNals(carry, true);
      carry = new Uint8Array(0);
      return extracted.nals;
    },
  };
}

function splitAnnexBNals(data, flush) {
  const nals = [];
  if (!data || data.byteLength < 4) {
    return {nals, rest: data || new Uint8Array(0)};
  }

  let source = data;
  let first = findAnnexBStartCode(source, 0);
  if (!first) {
    const rest = flush ? new Uint8Array(0) : source.slice(Math.max(0, source.byteLength - 4));
    return {nals, rest};
  }

  if (first.index > 0) {
    source = source.slice(first.index);
    first = {index: 0, length: first.length};
  }

  const starts = [first];
  let cursor = first.index + first.length;
  while (true) {
    const next = findAnnexBStartCode(source, cursor);
    if (!next) {
      break;
    }
    starts.push(next);
    cursor = next.index + next.length;
  }

  for (let i = 0; i < starts.length - 1; i += 1) {
    const start = starts[i];
    const next = starts[i + 1];
    const nal = source.slice(start.index + start.length, next.index);
    if (nal.byteLength > 0) {
      nals.push(nal);
    }
  }

  if (flush) {
    const last = starts[starts.length - 1];
    const tail = source.slice(last.index + last.length);
    if (tail.byteLength > 0) {
      nals.push(tail);
    }
    return {nals, rest: new Uint8Array(0)};
  }

  const rest = source.slice(starts[starts.length - 1].index);
  return {nals, rest};
}

function findAnnexBStartCode(data, fromIndex) {
  const start = Math.max(0, fromIndex);
  for (let i = start; i < data.byteLength - 3; i += 1) {
    if (data[i] !== 0x00 || data[i + 1] !== 0x00) {
      continue;
    }
    if (data[i + 2] === 0x01) {
      return {index: i, length: 3};
    }
    if (data[i + 2] === 0x00 && data[i + 3] === 0x01) {
      return {index: i, length: 4};
    }
  }
  return null;
}

function nalTypeOf(nal) {
  if (!nal || nal.byteLength === 0) {
    return 0;
  }
  return nal[0] & 0x1f;
}

function isFirstSliceNal(nal) {
  const type = nalTypeOf(nal);
  if (type !== 1 && type !== 5) {
    return false;
  }
  if (!nal || nal.byteLength < 2) {
    return false;
  }
  const rbsp = removeEmulationPreventionBytes(nal.subarray(1));
  const ue = readUnsignedExpGolomb(rbsp, 0);
  return ue ? ue.value === 0 : false;
}

function removeEmulationPreventionBytes(bytes) {
  const out = [];
  for (let i = 0; i < bytes.byteLength; i += 1) {
    if (
      i >= 2
      && bytes[i] === 0x03
      && bytes[i - 1] === 0x00
      && bytes[i - 2] === 0x00
    ) {
      continue;
    }
    out.push(bytes[i]);
  }
  return Uint8Array.from(out);
}

function readUnsignedExpGolomb(bytes, bitOffset) {
  const maxBits = bytes.byteLength * 8;
  if (bitOffset >= maxBits) {
    return null;
  }
  let leadingZeroBits = 0;
  while (bitOffset + leadingZeroBits < maxBits && readBit(bytes, bitOffset + leadingZeroBits) === 0) {
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
    const bit = readBit(bytes, bitOffset + leadingZeroBits + 1 + i);
    value = (value << 1) | bit;
  }
  return {
    value: value - 1,
    bits: leadingZeroBits * 2 + 1,
  };
}

function readBit(bytes, bitIndex) {
  const byteIndex = bitIndex >> 3;
  if (byteIndex < 0 || byteIndex >= bytes.byteLength) {
    return 0;
  }
  const offset = 7 - (bitIndex & 7);
  return (bytes[byteIndex] >> offset) & 1;
}

function extractCodecStringFromAccessUnit(accessUnit) {
  if (!accessUnit || !Array.isArray(accessUnit.nals)) {
    return '';
  }
  for (const nal of accessUnit.nals) {
    const codec = extractCodecStringFromSpsNal(nal);
    if (codec) {
      return codec;
    }
  }
  return '';
}

function extractCodecStringFromAnnexBPacket(packet) {
  const extracted = splitAnnexBNals(packet, true);
  for (const nal of extracted.nals) {
    const codec = extractCodecStringFromSpsNal(nal);
    if (codec) {
      return codec;
    }
  }
  return '';
}

function containsAnnexBNalType(packet, targetType) {
  const extracted = splitAnnexBNals(packet, true);
  for (const nal of extracted.nals) {
    if (nalTypeOf(nal) === targetType) {
      return true;
    }
  }
  if (packet && packet.byteLength > 0) {
    return nalTypeOf(packet) === targetType;
  }
  return false;
}

function extractCodecStringFromSpsNal(nal) {
  if (!nal || nal.byteLength < 4) {
    return '';
  }
  if (nalTypeOf(nal) !== 7) {
    return '';
  }
  return `avc1.${toHexByte(nal[1])}${toHexByte(nal[2])}${toHexByte(nal[3])}`;
}

function toHexByte(value) {
  return (value & 0xff).toString(16).toUpperCase().padStart(2, '0');
}

function joinAnnexBNals(nals) {
  let total = 0;
  for (const nal of nals) {
    total += 4 + nal.byteLength;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const nal of nals) {
    out[offset++] = 0x00;
    out[offset++] = 0x00;
    out[offset++] = 0x00;
    out[offset++] = 0x01;
    out.set(nal, offset);
    offset += nal.byteLength;
  }
  return out;
}

function concatUint8(left, right) {
  if (!left || left.byteLength === 0) {
    return right ? right.slice() : new Uint8Array(0);
  }
  if (!right || right.byteLength === 0) {
    return left.slice();
  }
  const out = new Uint8Array(left.byteLength + right.byteLength);
  out.set(left, 0);
  out.set(right, left.byteLength);
  return out;
}

function getInitialVideoSize() {
  const width = Math.max(320, Math.min(1920, Math.round(el.viewer.clientWidth || 720)));
  const height = Math.max(240, Math.min(1920, Math.round(el.viewer.clientHeight || 1280)));
  return {width, height};
}

function yuv420ToRgba(yuv, width, height, rgba) {
  const frameSize = width * height;
  const chromaSize = frameSize >> 2;
  let rgbaIndex = 0;
  for (let y = 0; y < height; y++) {
    const yRow = y * width;
    const uvRow = (y >> 1) * (width >> 1);
    for (let x = 0; x < width; x++) {
      const yValue = yuv[yRow + x] - 16;
      const uvIndex = uvRow + (x >> 1);
      const uValue = yuv[frameSize + uvIndex] - 128;
      const vValue = yuv[frameSize + chromaSize + uvIndex] - 128;

      const c = yValue < 0 ? 0 : yValue;
      const r = (298 * c + 409 * vValue + 128) >> 8;
      const g = (298 * c - 100 * uValue - 208 * vValue + 128) >> 8;
      const b = (298 * c + 516 * uValue + 128) >> 8;

      rgba[rgbaIndex++] = clampByte(r);
      rgba[rgbaIndex++] = clampByte(g);
      rgba[rgbaIndex++] = clampByte(b);
      rgba[rgbaIndex++] = 255;
    }
  }
}

function clampByte(value) {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return value;
}

function waitIceGatheringComplete(peer, timeoutMs) {
  if (peer.iceGatheringState === 'complete') {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timer);
      peer.removeEventListener('icegatheringstatechange', onState);
      resolve();
    };
    const onState = () => {
      if (peer.iceGatheringState === 'complete') {
        finish();
      }
    };
    const timer = setTimeout(finish, timeoutMs);
    peer.addEventListener('icegatheringstatechange', onState);
  });
}

async function applySettings() {
  const payload = {
    mjpegServerFramerate: normalizeSettingInput(el.fpsInput, 10),
    mjpegServerScreenshotQuality: normalizeSettingInput(el.qualityInput, 40),
    mjpegScalingFactor: normalizeSettingInput(el.scaleInput, 100),
    mjpegFixOrientation: el.fixOrientationInput.checked,
  };
  const data = await apiPost('/api/settings', payload);
  applySettingsInputs(data.clientSettings || data.sent || payload);
  logData('SETTINGS', data);

  // H264 decoders can lose sync when WDA scale/fps changes.
  // Restart non-MJPEG renderer so Genymobile/scrcpy and WebCodecs pick new stream params cleanly.
  if (state.selectedMode && !FRAME_IMAGE_VIEW_MODES.includes(state.selectedMode)) {
    await applySelectedViewMode(true);
  }
}

function applySettingsInputs(settings) {
  if (!settings || typeof settings !== 'object') {
    return;
  }
  if (settings.mjpegServerFramerate !== undefined) {
    el.fpsInput.value = String(normalizeSettingValue(
      settings.mjpegServerFramerate,
      Number(el.fpsInput.min) || 1,
      Number(el.fpsInput.max) || 60,
      10,
    ));
  }
  if (settings.mjpegServerScreenshotQuality !== undefined) {
    el.qualityInput.value = String(normalizeSettingValue(
      settings.mjpegServerScreenshotQuality,
      Number(el.qualityInput.min) || 1,
      Number(el.qualityInput.max) || 100,
      40,
    ));
  }
  if (settings.mjpegScalingFactor !== undefined) {
    el.scaleInput.value = String(normalizeSettingValue(
      settings.mjpegScalingFactor,
      Number(el.scaleInput.min) || 1,
      Number(el.scaleInput.max) || 100,
      100,
    ));
  }
  if (settings.mjpegFixOrientation !== undefined) {
    el.fixOrientationInput.checked = Boolean(settings.mjpegFixOrientation);
  }
  syncRangeSettingDisplays();
}

function normalizeSettingInput(inputEl, fallback) {
  const min = Number(inputEl.min);
  const max = Number(inputEl.max);
  const normalized = normalizeSettingValue(
    Number(inputEl.value),
    Number.isFinite(min) ? min : 1,
    Number.isFinite(max) ? max : 100,
    fallback,
  );
  inputEl.value = String(normalized);
  return normalized;
}

function normalizeSettingValue(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    return fallback;
  }
  return Math.round(clamp(n, min, max));
}

function bindRangeSetting(inputEl, valueEl, suffix = '') {
  if (!inputEl || !valueEl) {
    return;
  }
  const refresh = () => updateRangeSettingDisplay(inputEl, valueEl, suffix);
  inputEl.addEventListener('input', refresh);
  inputEl.addEventListener('change', refresh);
}

function updateRangeSettingDisplay(inputEl, valueEl, suffix = '') {
  if (!inputEl || !valueEl) {
    return;
  }
  valueEl.textContent = `${inputEl.value}${suffix}`;
}

function syncRangeSettingDisplays() {
  updateRangeSettingDisplay(el.fpsInput, el.fpsValue, ' fps');
  updateRangeSettingDisplay(el.qualityInput, el.qualityValue, '%');
  updateRangeSettingDisplay(el.scaleInput, el.scaleValue, '%');
}

function applyScreenInfo(screen) {
  if (!screen || !screen.screenSize) {
    return;
  }
  state.screen = screen;
  const size = screen.screenSize;
  applyViewerAspect(size.width, size.height);
  el.screenInfoLabel.textContent = `${size.width}x${size.height} @ scale ${screen.scale ?? '?'}`;
}

function eventToDevicePoint(event) {
  if (!state.screen || !state.screen.screenSize) {
    showError(new Error('No WDA screenSize yet. Connect WDA first.'));
    return null;
  }
  const rect = getActiveSurfaceRect();
  if (!rect.width || !rect.height) {
    return null;
  }
  const coordinateSize = getDisplayedDeviceCoordinateSize();
  const x = clamp((event.clientX - rect.left) / rect.width, 0, 1) * coordinateSize.width;
  const y = clamp((event.clientY - rect.top) / rect.height, 0, 1) * coordinateSize.height;
  return {x: Math.round(x), y: Math.round(y)};
}

function getDisplayedDeviceCoordinateSize() {
  const screenSize = state.screen?.screenSize;
  const width = Number(screenSize?.width) || 0;
  const height = Number(screenSize?.height) || 0;
  const surfaceSize = getActiveSurfacePixelSize();
  if (
    width <= 0 ||
    height <= 0 ||
    surfaceSize.width <= 0 ||
    surfaceSize.height <= 0
  ) {
    return {width, height};
  }

  // WDA may keep reporting the portrait screen size after an iPad rotates,
  // while MJPEG_FIX_ORIENTATION rotates the actual video frame. Coordinates
  // must follow the displayed frame orientation in that case.
  const screenIsLandscape = width > height;
  const surfaceIsLandscape = surfaceSize.width > surfaceSize.height;
  return screenIsLandscape === surfaceIsLandscape
    ? {width, height}
    : {width: height, height: width};
}

function getActiveSurfacePixelSize() {
  const surface = state.activeSurface;
  const dataWidth = Number(surface?.dataset?.frameWidth) || 0;
  const dataHeight = Number(surface?.dataset?.frameHeight) || 0;
  if (dataWidth > 0 && dataHeight > 0) {
    return {width: dataWidth, height: dataHeight};
  }
  if (surface instanceof HTMLImageElement) {
    return {
      width: Number(surface.naturalWidth) || 0,
      height: Number(surface.naturalHeight) || 0,
    };
  }
  if (surface instanceof HTMLVideoElement) {
    return {
      width: Number(surface.videoWidth) || 0,
      height: Number(surface.videoHeight) || 0,
    };
  }
  if (surface instanceof HTMLCanvasElement) {
    return {
      width: Number(surface.width) || 0,
      height: Number(surface.height) || 0,
    };
  }
  return {width: 0, height: 0};
}

function getActiveSurfaceRect() {
  if (state.activeSurface) {
    const rect = state.activeSurface.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) {
      const surfaceSize = getActiveSurfacePixelSize();
      const usesContain =
        state.activeSurface instanceof HTMLImageElement ||
        state.activeSurface instanceof HTMLVideoElement;
      if (
        usesContain &&
        surfaceSize.width > 0 &&
        surfaceSize.height > 0
      ) {
        const scale = Math.min(
          rect.width / surfaceSize.width,
          rect.height / surfaceSize.height,
        );
        const width = surfaceSize.width * scale;
        const height = surfaceSize.height * scale;
        return {
          left: rect.left + (rect.width - width) / 2,
          top: rect.top + (rect.height - height) / 2,
          right: rect.left + (rect.width + width) / 2,
          bottom: rect.top + (rect.height + height) / 2,
          width,
          height,
        };
      }
      return rect;
    }
  }
  return el.viewer.getBoundingClientRect();
}

function ensureTouchIndicator() {
  if (state.touchIndicator && state.touchIndicator.isConnected) {
    return state.touchIndicator;
  }
  const indicator = document.createElement('div');
  indicator.className = 'touch-indicator';
  (el.gestureOverlay || el.viewer).appendChild(indicator);
  state.touchIndicator = indicator;
  return indicator;
}

function ensureHoverIndicator() {
  if (state.hoverIndicator && state.hoverIndicator.isConnected) {
    return state.hoverIndicator;
  }
  const indicator = document.createElement('div');
  indicator.className = 'hover-indicator';
  (el.gestureOverlay || el.viewer).appendChild(indicator);
  state.hoverIndicator = indicator;
  return indicator;
}

function showHoverIndicator(clientX, clientY) {
  const rect = el.viewer.getBoundingClientRect();
  if (!rect.width || !rect.height) {
    return;
  }
  const x = clamp(clientX - rect.left, 0, rect.width);
  const y = clamp(clientY - rect.top, 0, rect.height);
  const indicator = ensureHoverIndicator();
  indicator.style.left = `${x}px`;
  indicator.style.top = `${y}px`;
  indicator.classList.add('active');
  el.viewer.classList.add('viewer-hover');
}

function hideHoverIndicator() {
  if (!state.hoverIndicator) {
    el.viewer.classList.remove('viewer-hover');
    return;
  }
  state.hoverIndicator.classList.remove('active');
  el.viewer.classList.remove('viewer-hover');
}

function showTouchIndicator(clientX, clientY) {
  const rect = el.viewer.getBoundingClientRect();
  if (!rect.width || !rect.height) {
    return;
  }
  const x = clamp(clientX - rect.left, 0, rect.width);
  const y = clamp(clientY - rect.top, 0, rect.height);
  const indicator = ensureTouchIndicator();
  indicator.style.left = `${x}px`;
  indicator.style.top = `${y}px`;
  indicator.classList.add('active');
  indicator.classList.remove('release');
  if (state.touchHideTimer) {
    clearTimeout(state.touchHideTimer);
    state.touchHideTimer = 0;
  }
}

function hideTouchIndicator() {
  if (!state.touchIndicator) {
    return;
  }
  state.touchIndicator.classList.remove('active');
  state.touchIndicator.classList.add('release');
  if (state.touchHideTimer) {
    clearTimeout(state.touchHideTimer);
  }
  state.touchHideTimer = setTimeout(() => {
    if (!state.touchIndicator) {
      return;
    }
    state.touchIndicator.classList.remove('release');
    state.touchHideTimer = 0;
  }, 180);
}

function flashPoint(clientX, clientY) {
  const rect = el.viewer.getBoundingClientRect();
  const dot = document.createElement('div');
  dot.className = 'tap-dot';
  dot.style.left = `${clientX - rect.left}px`;
  dot.style.top = `${clientY - rect.top}px`;
  el.viewer.appendChild(dot);
  setTimeout(() => dot.remove(), 400);
}

function setStreamState(text, ok) {
  if (!el.streamState) {
    return;
  }
  el.streamState.textContent = text;
  if (ok) {
    el.streamState.classList.add('ok');
  } else {
    el.streamState.classList.remove('ok');
  }
}

async function apiGet(url) {
  const response = await fetch(url, {
    headers: authHeaders(),
  });
  return readApiResponse(response);
}

async function apiPost(url, body) {
  const response = await fetch(url, {
    method: 'POST',
    headers: authHeaders({'content-type': 'application/json'}),
    body: JSON.stringify(body || {}),
  });
  return readApiResponse(response);
}

async function readApiResponse(response) {
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.ok === false) {
    throw new Error(payload.error || `${response.status} ${response.statusText}`);
  }
  return payload;
}

function showError(err) {
  log(err.message || String(err), true);
}

function authHeaders(headers = {}) {
  if (!APP_AUTH_TOKEN) {
    return headers;
  }
  return {...headers, Authorization: `Bearer ${APP_AUTH_TOKEN}`};
}

function initAuthToken() {
  try {
    const params = new URLSearchParams(location.search);
    const token = String(params.get('auth') || params.get('token') || '').trim();
    if (token) {
      localStorage.setItem(AUTH_STORAGE_KEY, token);
      params.delete('auth');
      params.delete('token');
      const nextQuery = params.toString();
      history.replaceState(
        null,
        '',
        `${location.pathname}${nextQuery ? `?${nextQuery}` : ''}${location.hash}`,
      );
      return token;
    }
    return String(localStorage.getItem(AUTH_STORAGE_KEY) || '').trim();
  } catch (_) {
    return '';
  }
}

function logData(label, data) {
  log(`${label}\n${JSON.stringify(data, null, 2)}`);
}

function log(message, isError = false) {
  const timestamp = new Date().toLocaleTimeString();
  const line = `[${timestamp}] ${message}`;
  el.logBox.textContent = `${line}\n\n${el.logBox.textContent}`.slice(0, 16000);
  if (isError) {
    setStreamState('error', false);
  }
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
