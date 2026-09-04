'use strict';

const AUTH_STORAGE_KEY = 'ios_wda_stream_auth_token';
const APP_AUTH_TOKEN = initAuthToken();

const state = {
  actions: new Map(),
  devices: [],
  busy: false,
};

const el = {
  refreshDevicesBtn: document.getElementById('refreshDevicesBtn'),
  deviceSelect: document.getElementById('deviceSelect'),
  udidInput: document.getElementById('udidInput'),
  setupState: document.getElementById('setupState'),
  iosBinLabel: document.getElementById('iosBinLabel'),
  setupLog: document.getElementById('setupLog'),
  lastCommandLabel: document.getElementById('lastCommandLabel'),
};

init().catch((err) => {
  setSetupState('error', false);
  appendLog(`init error: ${err.message || String(err)}`);
});

async function init() {
  bindUi();
  await loadActions();
  await refreshDevices();
}

function bindUi() {
  el.refreshDevicesBtn.addEventListener('click', () => {
    refreshDevices().catch(showError);
  });
  el.deviceSelect.addEventListener('change', () => {
    const selected = state.devices.find((device) => device.udid === el.deviceSelect.value);
    if (selected) {
      el.udidInput.value = selected.udid;
    }
  });
  document.querySelectorAll('[data-action]').forEach((button) => {
    button.addEventListener('click', () => {
      runAction(button.dataset.action).catch(showError);
    });
  });
}

async function loadActions() {
  const data = await apiGet('/api/setup/actions');
  state.actions = new Map((data.actions || []).map((item) => [item.id, item]));
  el.iosBinLabel.textContent = data.goIosBin || 'ios';
}

async function refreshDevices() {
  setSetupState('loading devices', false);
  const data = await apiGet('/api/setup/devices');
  state.devices = Array.isArray(data.devices) ? data.devices : [];
  renderDevices();
  renderResult('Refresh devices', data.result || data);
  setSetupState(data.ok ? 'ready' : 'device list failed', Boolean(data.ok));
}

function renderDevices() {
  const current = el.udidInput.value.trim();
  el.deviceSelect.innerHTML = '';
  if (state.devices.length === 0) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'No devices';
    el.deviceSelect.appendChild(option);
    return;
  }
  for (const device of state.devices) {
    const option = document.createElement('option');
    option.value = device.udid;
    const version = device.productVersion ? ` iOS ${device.productVersion}` : '';
    const model = device.productType ? ` ${device.productType}` : '';
    option.textContent = `${device.name || 'iOS device'}${model}${version}`;
    option.title = device.udid;
    if (device.udid === current || (!current && el.deviceSelect.options.length === 0)) {
      option.selected = true;
      el.udidInput.value = device.udid;
    }
    el.deviceSelect.appendChild(option);
  }
}

async function runAction(action) {
  if (state.busy) {
    return;
  }
  const actionInfo = state.actions.get(action);
  if (!actionInfo) {
    throw new Error(`Unknown action: ${action}`);
  }
  const udid = el.udidInput.value.trim();
  if (actionInfo.requiresUdid && !udid) {
    throw new Error(`${actionInfo.label || action} requires UDID`);
  }

  state.busy = true;
  setButtonsDisabled(true);
  setSetupState(`running ${actionInfo.label || action}`, false);
  try {
    const data = await apiPost('/api/setup/run', {action, udid});
    renderResult(data.label || action, data.result || data);
    setSetupState(data.ok ? 'done' : 'failed', Boolean(data.ok));
  } finally {
    state.busy = false;
    setButtonsDisabled(false);
  }
}

function renderResult(label, result) {
  const command = result?.command || '-';
  el.lastCommandLabel.textContent = command;
  const parts = [
    `[${new Date().toLocaleTimeString()}] ${label}`,
    `command: ${command}`,
    `ok: ${Boolean(result?.ok)} code: ${result?.code ?? '-'} signal: ${result?.signal ?? '-'}`,
  ];
  if (result?.timedOut) {
    parts.push('timed out: true');
  }
  if (result?.stdout) {
    parts.push('', '--- stdout ---', result.stdout.trimEnd());
  }
  if (result?.stderr) {
    parts.push('', '--- stderr ---', result.stderr.trimEnd());
  }
  if (result?.error) {
    parts.push('', `error: ${result.error}`);
  }
  if (result?.stdoutTruncated || result?.stderrTruncated) {
    parts.push('', 'output truncated');
  }
  appendLog(parts.join('\n'));
}

function appendLog(text) {
  const divider = el.setupLog.textContent ? '\n\n' : '';
  el.setupLog.textContent = `${divider}${text}${el.setupLog.textContent}`;
}

function setSetupState(text, ok) {
  el.setupState.textContent = text;
  el.setupState.classList.toggle('ok', Boolean(ok));
}

function setButtonsDisabled(disabled) {
  document.querySelectorAll('button').forEach((button) => {
    button.disabled = Boolean(disabled);
  });
}

function showError(err) {
  setSetupState('error', false);
  appendLog(`error: ${err.message || String(err)}`);
}

async function apiGet(path) {
  return requestJson(path, {
    method: 'GET',
    headers: authHeaders(),
  });
}

async function apiPost(path, body) {
  return requestJson(path, {
    method: 'POST',
    headers: authHeaders({'content-type': 'application/json'}),
    body: JSON.stringify(body || {}),
  });
}

async function requestJson(path, options) {
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.error || `${response.status} ${response.statusText}`);
  }
  return data;
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
