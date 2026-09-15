// The panel. No framework and no CDN on purpose: the machine this runs on may
// have no network at all once the weights are down, and the rest of this
// project installs nothing either.
//
// Every number shown here comes from the server, which computes it with the
// same lib/fit.ps1 the terminal launcher uses. This file decides layout and
// nothing else - a fit table drawn from arithmetic reimplemented in JavaScript
// would be a second opinion, and two opinions is what the project exists to
// avoid.

const state = {
  step: 'model',
  data: null,
  backendKey: null,
  modelKey: null,
  vision: false,
  cacheType: null,
  context: null,
  fit: null,
  progress: null,
  server: null,
  busy: false,
};

const screen = document.getElementById('screen');
const crumbs = document.getElementById('crumbs');
const badge = document.getElementById('serverBadge');
const meter = document.getElementById('meter');

const mib = (value) => {
  if (value === null || value === undefined) return '—';
  return value >= 1024 ? `${(value / 1024).toFixed(1)} GiB` : `${Math.round(value)} MiB`;
};
const k = (context) => `${context / 1024}K`;

async function api(path, body) {
  const options = body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : {};
  const response = await fetch(path, options);
  if (!response.ok) throw new Error(`${path} -> ${response.status}`);
  return response.json();
}

// ------------------------------------------------------------------ chrome

function renderCrumbs() {
  const steps = [['model', 'Model'], ['options', 'Fit'], ['run', 'Run']];
  crumbs.innerHTML = steps
    .map(([id, label]) => `<span class="${state.step === id ? 'on' : ''}">${label}</span>`)
    .join('<span>›</span>');
}

function renderBadge() {
  const server = state.server;
  if (!server) { badge.textContent = 'checking…'; badge.className = 'badge'; return; }
  if (server.running) {
    badge.textContent = server.model ? `running · ${server.model}` : 'running';
    badge.className = 'badge live';
  } else if (server.loading) {
    badge.textContent = 'loading model…';
    badge.className = 'badge busy';
  } else {
    badge.textContent = 'no model loaded';
    badge.className = 'badge';
  }
}

function renderMeter() {
  const fit = state.fit;
  if (!fit || state.step === 'run') { meter.innerHTML = ''; return; }
  const row = (fit.rows || []).find((entry) => entry.context === state.context);
  if (!row) { meter.innerHTML = `<span>${fit.deviceName} · ${mib(fit.budgetMiB)} usable</span>`; return; }
  const percent = Math.min(100, (row.totalMiB / fit.budgetMiB) * 100);
  const tone = row.fits ? '' : row.tight ? ' tight' : ' over';
  meter.innerHTML = `
    <span>${mib(row.totalMiB)} of ${mib(fit.budgetMiB)}</span>
    <span class="track"><span class="fill${tone}" style="width:${percent}%"></span></span>
    <span>${fit.deviceName}</span>`;
}

// ------------------------------------------------------------------ screens

function modelScreen() {
  const data = state.data;
  const backends = data.backends;
  const parts = [];

  if (backends.length > 1) {
    parts.push(`<div class="section"><h2>Backend</h2><div class="grid">` + backends.map((backend) => `
      <button class="tile" data-nav data-action="backend" data-key="${backend.key}" aria-pressed="${backend.key === state.backendKey}">
        <span class="title">${backend.name}</span>
        <span class="meta">${backend.devices.length ? backend.devices[0].name : 'no GPU · system RAM'} · ${mib(backend.budgetMiB)} usable</span>
        ${backend.installed ? '' : '<span class="row"><span class="pill warn">will be downloaded</span></span>'}
      </button>`).join('') + `</div></div>`);
  }

  parts.push(`<div class="section"><h2>Model</h2><div class="grid">` + data.models.map((model) => {
    const pills = [];
    if (model.downloaded) pills.push(`<span class="pill good">${mib(model.weightsMiB)} here</span>`);
    else pills.push('<span class="pill warn">will be downloaded</span>');
    if (model.hasVision) pills.push('<span class="pill">vision</span>');
    if (model.specType) pills.push(`<span class="pill">${model.specType}</span>`);
    return `
      <button class="tile" data-nav data-action="model" data-key="${model.key}" aria-pressed="${model.key === state.modelKey}">
        <span class="title">${model.name}</span>
        <span class="meta">${model.summary || model.alias}</span>
        <span class="row">${pills.join('')}</span>
      </button>`;
  }).join('') + `</div></div>`);

  return `<h1>What do you want to run?</h1>
    <p class="sub">Sizes are what is on disk. Anything missing is downloaded and checked against its SHA-256 before it loads.</p>
    ${parts.join('')}`;
}

function optionsScreen() {
  const fit = state.fit;
  const model = state.data.models.find((entry) => entry.key === state.modelKey);
  if (!fit) return `<h1>${model.name}</h1><p class="sub"><span class="spin"></span> Working out what fits…</p>`;

  const spec = fit.spec[String(state.context)] || {};
  const notices = [];
  if (!fit.overheadCalibrated) {
    notices.push(`<div class="notice">No overhead ${fit.overheadMissing} yet, so constants fitted to something else are standing in. The KV column is exact; the estimated total is a guess.</div>`);
  }
  if (!fit.downloaded) {
    notices.push(`<div class="notice plain">Not downloaded yet. The table below uses the sizes this model declares; it is recomputed from the real file once it is here.</div>`);
  }

  const visionTiles = model.hasVision ? `
    <div class="section"><h2>Vision encoder</h2><div class="grid">
      <button class="tile" data-nav data-action="vision" data-key="on" aria-pressed="${state.vision}">
        <span class="title">With vision</span>
        <span class="meta">Images, video and audio in. Costs ${mib(fit.visionMiB || model.visionMiB)} plus its compute buffers.</span>
      </button>
      <button class="tile" data-nav data-action="vision" data-key="off" aria-pressed="${!state.vision}">
        <span class="title">Text only</span>
        <span class="meta">Leaves that memory for context.</span>
      </button>
    </div></div>` : '';

  const cacheTiles = `
    <div class="section"><h2>KV cache</h2><div class="grid">` + state.data.cacheTypes.map((cache) => `
      <button class="tile" data-nav data-action="cache" data-key="${cache.type}" aria-pressed="${cache.type === state.cacheType}">
        <span class="title">${cache.type}</span>
        <span class="meta">${cache.bytes} bytes per element${cache.type === model.cacheDefault ? ' · what the catalog picks here' : ''}</span>
      </button>`).join('') + `</div></div>`;

  const contextTiles = `
    <div class="section"><h2>Context</h2><div class="fit">` + fit.rows.map((row) => {
      const verdict = row.fits ? '<span class="pill good">FITS</span>'
        : row.tight ? '<span class="pill warn">TIGHT</span>'
        : '<span class="pill bad">TOO BIG</span>';
      return `
        <button class="tile ${row.tight ? '' : 'dim'}" data-nav data-action="context" data-key="${row.context}" aria-pressed="${row.context === state.context}">
          <span class="ctx">${k(row.context)}</span>
          <span class="meta">KV ${mib(row.kvMiB)} · total ${mib(row.totalMiB)}</span>
          <span class="row">${verdict}</span>
        </button>`;
    }).join('') + `</div></div>`;

  const specSection = `
    <div class="section"><h2>Speculative decoding</h2>
      <div class="notice plain">${spec.use ? `On: ${spec.reason}` : `Off: ${spec.reason}`}${spec.note ? `<br>${spec.note}` : ''}</div>
    </div>`;

  return `<h1>${model.name}</h1>
    <p class="sub">${fit.deviceName} · ${mib(fit.budgetMiB)} usable${fit.heldBackMiB ? `, holding back ${mib(fit.heldBackMiB)}` : ''}</p>
    ${notices.join('')}
    ${visionTiles}${cacheTiles}${contextTiles}${specSection}
    <div class="actions">
      <button class="btn primary" data-nav data-action="start">Load it</button>
      <button class="btn" data-nav data-action="back">Back</button>
    </div>`;
}

function runScreen() {
  const server = state.server || {};
  const progress = state.progress;

  if (progress && progress.state && progress.state !== 'ready' && progress.state !== 'idle') {
    const items = (progress.artifacts || []).map((item) => `
      <div class="item">
        <div><b>${item.label}</b> ${item.done ? '<span class="pill good">verified</span>' : ''}</div>
        <div class="meta">${item.done ? 'on disk' : item.percent !== null ? `${item.percent}% of ${mib(item.expected / 1048576)}` : 'starting…'}</div>
        <div class="track"><span class="fill" style="width:${item.done ? 100 : (item.percent || 0)}%"></span></div>
      </div>`).join('');
    return `<h1><span class="spin"></span> ${progress.message || 'Working'}</h1>
      <p class="sub">Every file is checked against its SHA-256 before anything loads. You can leave this screen open on your phone.</p>
      <div class="progress">${items}</div>`;
  }

  if (server.loading) {
    return `<h1><span class="spin"></span> Loading the model</h1>
      <p class="sub">llama.cpp is reading the weights onto the device. A 16 GB model takes a minute or two.</p>`;
  }

  if (!server.running) {
    return `<h1>Nothing loaded</h1>
      <p class="sub">Pick a model and it will be here.</p>
      <div class="actions"><button class="btn primary" data-nav data-action="back">Choose a model</button></div>`;
  }

  const urls = [];
  urls.push(`<div class="url"><div class="label">Chat UI on this machine</div><div class="value">${server.chat}</div></div>`);
  if (server.lanChat) urls.push(`<div class="url"><div class="label">From any device on this network</div><div class="value">${server.lanChat}</div></div>`);
  if (server.mdnsChat) urls.push(`<div class="url"><div class="label">Or, where mDNS resolves</div><div class="value">${server.mdnsChat}</div></div>`);
  urls.push(`<div class="url"><div class="label">OpenAI-compatible API</div><div class="value">${server.lanApi || server.api}</div></div>`);

  return `<h1>${server.model || 'Model'} is running</h1>
    <p class="sub">The server outlives this panel. Closing the page changes nothing.</p>
    <div class="urls">${urls}</div>
    <div class="actions">
      <button class="btn primary" data-nav data-action="chat">Open the chat UI</button>
      <button class="btn" data-nav data-action="back">Load something else</button>
      <button class="btn danger" data-nav data-action="stop">Stop the server</button>
    </div>`;
}

function render() {
  renderCrumbs();
  renderBadge();
  if (state.step === 'model') screen.innerHTML = modelScreen();
  else if (state.step === 'options') screen.innerHTML = optionsScreen();
  else screen.innerHTML = runScreen();
  renderMeter();
  focusFirst();
}

// -------------------------------------------------------------- navigation

// Focus is moved rather than emulated: every tile is a real button, so a tap, a
// click from the thumbstick cursor, Enter from a keyboard and A on a pad all
// take the same path through the DOM.
function navItems() { return Array.from(screen.querySelectorAll('[data-nav]')); }

function focusFirst() {
  const items = navItems();
  if (!items.length) return;
  const pressed = items.find((item) => item.getAttribute('aria-pressed') === 'true');
  (pressed || items[0]).focus({ preventScroll: true });
}

function moveFocus(direction) {
  const items = navItems();
  if (!items.length) return;
  const current = document.activeElement;
  const index = items.indexOf(current);
  if (index === -1) { items[0].focus(); return; }

  if (direction === 'next' || direction === 'previous') {
    const next = index + (direction === 'next' ? 1 : -1);
    if (items[next]) items[next].focus({ preventScroll: true });
    return;
  }
  // Up and down jump by row, worked out from where things actually landed
  // rather than from a column count this file would have to guess.
  const box = current.getBoundingClientRect();
  const candidates = items
    .map((item) => ({ item, rect: item.getBoundingClientRect() }))
    .filter(({ rect }) => (direction === 'down' ? rect.top > box.bottom - 4 : rect.bottom < box.top + 4));
  if (!candidates.length) return;
  candidates.sort((a, b) => {
    const rowA = direction === 'down' ? a.rect.top : -a.rect.bottom;
    const rowB = direction === 'down' ? b.rect.top : -b.rect.bottom;
    if (Math.abs(rowA - rowB) > 4) return rowA - rowB;
    return Math.abs(a.rect.left - box.left) - Math.abs(b.rect.left - box.left);
  });
  candidates[0].item.focus({ preventScroll: true });
}

document.addEventListener('keydown', (event) => {
  const keys = {
    ArrowRight: 'next', ArrowLeft: 'previous', ArrowDown: 'down', ArrowUp: 'up',
  };
  if (keys[event.key]) { event.preventDefault(); moveFocus(keys[event.key]); return; }
  if (event.key === 'Escape' || event.key === 'Backspace') { event.preventDefault(); goBack(); }
});

// A gamepad reaches the page only when the browser hands it over; in Gaming
// Mode Steam usually drives a cursor instead, which is why nothing here
// depends on it. When it is there, the D-pad moves and A selects.
const pad = { previous: {}, timer: null };
function pollGamepad() {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  const active = Array.from(pads).find(Boolean);
  if (!active) return;
  const pressed = (index) => active.buttons[index] && active.buttons[index].pressed;
  const edge = (name, value) => {
    const was = pad.previous[name];
    pad.previous[name] = value;
    return value && !was;
  };
  const axisX = active.axes[0] || 0;
  const axisY = active.axes[1] || 0;
  if (edge('up', pressed(12) || axisY < -0.6)) moveFocus('up');
  if (edge('down', pressed(13) || axisY > 0.6)) moveFocus('down');
  if (edge('left', pressed(14) || axisX < -0.6)) moveFocus('previous');
  if (edge('right', pressed(15) || axisX > 0.6)) moveFocus('next');
  if (edge('a', pressed(0)) && document.activeElement) document.activeElement.click();
  if (edge('b', pressed(1))) goBack();
}
window.addEventListener('gamepadconnected', () => {
  if (!pad.timer) pad.timer = setInterval(pollGamepad, 90);
});

function goBack() {
  if (state.step === 'options') { state.step = 'model'; render(); }
  else if (state.step === 'run' && !(state.server && (state.server.running || state.server.loading))) {
    state.step = 'model'; render();
  }
}

// ------------------------------------------------------------------ actions

screen.addEventListener('click', async (event) => {
  const target = event.target.closest('[data-action]');
  if (!target || state.busy) return;
  const action = target.dataset.action;
  const key = target.dataset.key;

  if (action === 'backend') { state.backendKey = key; await refreshFit(); render(); }
  else if (action === 'model') {
    state.modelKey = key;
    const model = state.data.models.find((entry) => entry.key === key);
    state.vision = false;
    state.cacheType = model.cacheDefault;
    state.context = null;
    // Cleared before the screen is drawn: the previous model's table showing
    // for a moment under this model's name is a lie, however short.
    state.fit = null;
    state.step = 'options';
    render();
    await refreshFit();
    render();
  }
  else if (action === 'vision') { state.vision = key === 'on'; await refreshFit(); render(); }
  else if (action === 'cache') { state.cacheType = key; await refreshFit(); render(); }
  else if (action === 'context') { state.context = Number(key); renderMeter(); render(); }
  else if (action === 'back') { state.step = 'model'; render(); }
  else if (action === 'chat') { window.open(state.server.chat, '_blank'); }
  else if (action === 'stop') { state.busy = true; await api('/api/stop', {}); state.busy = false; await refreshStatus(); render(); }
  else if (action === 'start') await start();
});

async function refreshFit() {
  if (!state.modelKey || !state.backendKey) return;
  state.fit = await api('/api/fit', {
    modelKey: state.modelKey, backendKey: state.backendKey,
    vision: state.vision, cacheType: state.cacheType,
  });
  const rows = state.fit.rows;
  if (!rows.length) { state.context = null; return; }
  const current = rows.find((row) => row.context === state.context);
  if (!current) {
    // The same default the launcher picks: the longest length that still fits
    // comfortably, or the shortest one if none of them do.
    const fitting = rows.filter((row) => row.fits);
    state.context = (fitting.length ? fitting[fitting.length - 1] : rows[0]).context;
  }
}

async function start() {
  state.busy = true;
  state.step = 'run';
  state.progress = { state: 'starting', message: 'Checking what is already here', artifacts: [] };
  render();
  try {
    await api('/api/prepare', {
      modelKey: state.modelKey, backendKey: state.backendKey, vision: state.vision,
      cacheType: state.cacheType, context: state.context,
      spec: !!(state.fit.spec[String(state.context)] || {}).use,
    });
  } catch (error) {
    // Whatever went wrong, the panel has to come back: leaving it spinning is
    // worse than saying it failed, especially on a screen nobody is sitting at.
    state.busy = false;
    state.progress = null;
    screen.innerHTML = `<h1>That did not start</h1><p class="sub">${error.message}</p>
      <div class="actions"><button class="btn primary" data-nav data-action="back">Back</button></div>`;
    focusFirst();
    return;
  }

  // Poll until every file is verified, then ask for the server. Two phases,
  // because a 16 GB download and a model load fail for different reasons and
  // saying which one you are in is the difference between waiting and worrying.
  while (true) {
    await new Promise((resolve) => setTimeout(resolve, 1200));
    state.progress = await api('/api/progress');
    render();
    if (state.progress.state === 'ready') break;
    if (state.progress.state === 'failed') { state.busy = false; return; }
  }
  await api('/api/serve', {});
  state.progress = null;
  state.busy = false;
  await refreshStatus();
  render();
}

async function refreshStatus() {
  try { state.server = await api('/api/status'); } catch { state.server = null; }
}

// ------------------------------------------------------------------- start

async function boot() {
  state.data = await api('/api/state');
  state.server = state.data.server;
  state.backendKey = state.data.backends.length ? state.data.backends[0].key : null;
  if (state.server && (state.server.running || state.server.loading)) state.step = 'run';
  render();
  setInterval(async () => {
    if (state.busy) return;
    await refreshStatus();
    renderBadge();
    if (state.step === 'run') render();
  }, 3000);
}

boot().catch((error) => {
  screen.innerHTML = `<h1>The panel cannot reach its own server</h1><p class="sub">${error.message}</p>`;
});
