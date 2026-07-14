---
name: chat-ui-status
description: Framework-free chat UI with a live status bar that polls health + version endpoints so deploys, failures, and rollbacks are visible on screen. Use when building or reviewing the demo frontend in app/static/.
---

# Chat UI + Live Status Bar Pattern

A zero-build, vanilla HTML/CSS/JS demo frontend whose job is to make backend state changes **visible**: health flips, version/flavor changes, and garbage AI answers.

## Anatomy
- `index.html` — status bar header (health dot + version/flavor labels) above a chat panel (scrolling message list, input, send button).
- `app.js` — chat POSTs + status polling. No framework, no imports, no CDN.
- `style.css` — one accent color, distinct user vs agent bubbles, an `.error` bubble style that stands out.

## Status polling (the demo-critical part)
```js
const POLL_MS = 3000;
async function poll() {
  try {
    const h = await fetch('/healthz', { signal: AbortSignal.timeout(2500) });
    setDot(h.ok);                       // any non-2xx OR network error = red
  } catch { setDot(false); }            // fetch throws on timeout/refused — that's red too
  try {
    const v = await (await fetch('/version', { signal: AbortSignal.timeout(2500) })).json();
    versionEl.textContent = `${v.version} · ${v.build_flavor}`;
  } catch { /* keep last known version — during a rollout blip the label holding steady is fine */ }
}
setInterval(poll, POLL_MS); poll();
```

Rules:
- **The dot must go red on fetch REJECTION, not just non-200** — during a bad canary the request may time out or connection-refuse rather than return 500. Timeout must be shorter than the poll interval so polls don't pile up.
- Poll every 3–5s: fast enough that the red flash during a bad canary is visible on screen, slow enough not to spam logs.
- Show `build_flavor` prominently — the label flipping back after rollback IS the money shot.

## Chat behavior
- POST `{"prompt": text}` to `/agent`; render the reply as an agent bubble.
- On non-2xx or unparseable response, render the raw error/garbage **in the chat as an error-styled bubble** — never swallow it. In `bad_agent` mode the point is that the answer is visibly wrong while the health dot stays green.
- Disable input while a request is in flight; `Enter` sends; auto-scroll to newest message.
- Relative URLs only (`/agent`, `/healthz`, `/version`) — same origin as the FastAPI server; works unchanged local and in-cluster.
