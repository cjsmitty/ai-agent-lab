/* Harness AI Agent Lab — chat + live status bar.
 * Vanilla JS, no dependencies. Relative URLs only (same origin as FastAPI).
 */
'use strict';

// ---------- status bar polling ----------

const POLL_MS = 3000;      // 3–5s per skill
const FETCH_TIMEOUT = 2500; // must be shorter than POLL_MS so polls don't pile up

const healthDot = document.getElementById('health-dot');
const versionLabel = document.getElementById('version-label');
const flavorLabel = document.getElementById('flavor-label');
const failureLabel = document.getElementById('failure-label');

function setDot(ok) {
  healthDot.classList.remove('unknown', 'ok', 'bad');
  healthDot.classList.add(ok ? 'ok' : 'bad');
  healthDot.title = ok ? 'healthy' : 'UNHEALTHY';
}

async function poll() {
  // Health: any non-2xx OR fetch rejection (timeout / connection refused) = red.
  try {
    const h = await fetch('/healthz', { signal: AbortSignal.timeout(FETCH_TIMEOUT) });
    setDot(h.ok);
  } catch {
    setDot(false);
  }

  // Version/flavor: on failure keep the last known label — during a rollout
  // blip the label holding steady is fine.
  try {
    const r = await fetch('/version', { signal: AbortSignal.timeout(FETCH_TIMEOUT) });
    const v = await r.json();
    versionLabel.textContent = 'version: ' + v.version;
    flavorLabel.textContent = v.build_flavor;
    if (v.failure_mode && v.failure_mode !== 'none') {
      failureLabel.textContent = 'failure_mode: ' + v.failure_mode;
      failureLabel.classList.remove('hidden');
    } else {
      failureLabel.classList.add('hidden');
    }
  } catch {
    /* keep last known version */
  }
}

setInterval(poll, POLL_MS);
poll();

// ---------- chat ----------

const messagesEl = document.getElementById('messages');
const formEl = document.getElementById('chat-form');
const inputEl = document.getElementById('prompt-input');
const sendBtn = document.getElementById('send-btn');

function addBubble(text, kind, meta) {
  const row = document.createElement('div');
  row.className = 'row ' + kind;

  const bubble = document.createElement('div');
  bubble.className = 'bubble ' + kind;
  bubble.textContent = text;
  row.appendChild(bubble);

  if (meta) {
    const metaEl = document.createElement('div');
    metaEl.className = 'meta';
    metaEl.textContent = meta;
    row.appendChild(metaEl);
  }

  messagesEl.appendChild(row);
  messagesEl.scrollTop = messagesEl.scrollHeight; // auto-scroll to newest
}

function setBusy(busy) {
  inputEl.disabled = busy;
  sendBtn.disabled = busy;
  sendBtn.textContent = busy ? '…' : 'Send';
}

async function sendPrompt(prompt) {
  setBusy(true);
  addBubble(prompt, 'user');
  try {
    const res = await fetch('/agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt: prompt }),
    });

    const raw = await res.text();

    if (!res.ok) {
      // Non-2xx: show the raw error body in an error-styled bubble.
      addBubble('HTTP ' + res.status + ' — ' + raw, 'error');
      return;
    }

    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      // 200 but unparseable — never swallow it.
      addBubble('Unparseable response: ' + raw, 'error');
      return;
    }

    // Render whatever we got as the agent bubble — in bad_agent mode the
    // garbage response speaks for itself while the health dot stays green.
    const meta = [data.provider, data.tool_used ? 'tool: ' + data.tool_used : null]
      .filter(Boolean)
      .join(' · ');
    addBubble(String(data.response), 'agent', meta);
  } catch (err) {
    // Network error / timeout — error bubble, never silent.
    addBubble('Request failed: ' + err, 'error');
  } finally {
    setBusy(false);
    inputEl.focus();
  }
}

formEl.addEventListener('submit', (e) => {
  e.preventDefault(); // form submit covers both the button and Enter
  const prompt = inputEl.value.trim();
  if (!prompt || inputEl.disabled) return;
  inputEl.value = '';
  sendPrompt(prompt);
});

addBubble('Hi! Ask me something — try a calculation or a lookup.', 'agent');
inputEl.focus();
