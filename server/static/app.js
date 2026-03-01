/**
 * static/app.js  —  Dashboard client logic
 * Connects to the Flask-SocketIO server and drives all UI updates.
 */

"use strict";

// ── Socket connection ────────────────────────────────────────────────────────
const socket = io({ transports: ["websocket"], upgrade: false });

// ── DOM refs ─────────────────────────────────────────────────────────────────
const feedEl      = document.getElementById("feed");
const overlayEl   = document.getElementById("overlay");
const dotEl       = document.getElementById("dot");
const fpsDisplay  = document.getElementById("fps-display");
const frameTs     = document.getElementById("frame-ts");
const clockEl     = document.getElementById("clock");
const footerMsg   = document.getElementById("footer-msg");
const badgeLive   = document.getElementById("badge-live");

const statConnected = document.getElementById("stat-connected");
const statFrames    = document.getElementById("stat-frames");
const statFps       = document.getElementById("stat-fps");
const statLatency   = document.getElementById("stat-latency");
const statUtc       = document.getElementById("stat-utc");
const statLast      = document.getElementById("stat-last");

// ── State ─────────────────────────────────────────────────────────────────────
let frameCount = 0;
let lastFrameTime = 0;

// ── Clock (local, runs independently of server) ───────────────────────────────
function updateClock() {
  const now = new Date();
  clockEl.textContent = now.toLocaleTimeString("en-GB", { hour12: false });
}
setInterval(updateClock, 1000);
updateClock();

// ── Helpers ───────────────────────────────────────────────────────────────────
function setOnline(online) {
  dotEl.className    = "topbar__dot " + (online ? "live" : "offline");
  badgeLive.className = "badge " + (online ? "live" : "");
  badgeLive.textContent = online ? "● LIVE" : "● OFFLINE";

  statConnected.textContent = online ? "ONLINE" : "OFFLINE";
  statConnected.className   = "stat-val " + (online ? "online" : "offline");

  if (online) {
    overlayEl.classList.add("hidden");
    footerMsg.textContent = "Stream active";
  } else {
    overlayEl.classList.remove("hidden");
    feedEl.classList.remove("visible");
    footerMsg.textContent = "Camera disconnected — waiting for stream…";
  }
}

function fmtTime(isoStr) {
  if (!isoStr) return "—";
  try {
    return new Date(isoStr).toLocaleTimeString("en-GB", { hour12: false });
  } catch { return isoStr; }
}

// ── Socket events ─────────────────────────────────────────────────────────────
socket.on("connect", () => {
  footerMsg.textContent = "Connected to server";
});

socket.on("disconnect", () => {
  setOnline(false);
  fpsDisplay.textContent = "— fps";
  footerMsg.textContent = "Lost connection to server";
});

socket.on("status", (data) => {
  setOnline(!!data.connected);
  statFps.textContent     = data.fps != null ? data.fps.toFixed(1) : "—";
  statFrames.textContent  = data.frame_count ?? 0;
  fpsDisplay.textContent  = data.fps != null ? `${data.fps.toFixed(1)} fps` : "— fps";
  statUtc.textContent     = fmtTime(data.server_time);
  statLast.textContent    = fmtTime(data.last_seen);
});

socket.on("frame", (msg) => {
  const now = performance.now();

  // Render frame
  feedEl.src = `data:image/jpeg;base64,${msg.data}`;
  feedEl.classList.add("visible");
  overlayEl.classList.add("hidden");

  // Latency (client-side estimate: diff between server-assigned ts and now)
  if (msg.ts) {
    const latencyMs = Math.round((Date.now() / 1000 - msg.ts) * 1000);
    statLatency.textContent = latencyMs > 0 ? `${latencyMs} ms` : "—";
  }

  // Frame timestamp overlay
  const d = new Date();
  frameTs.textContent =
    `${d.toLocaleDateString("en-GB")}  ` +
    `${d.toLocaleTimeString("en-GB", { hour12: false })}.${String(d.getMilliseconds()).padStart(3,"0")}`;

  // Stats
  frameCount++;
  statFrames.textContent = frameCount;
  if (msg.fps != null) {
    statFps.textContent    = msg.fps.toFixed(1);
    fpsDisplay.textContent = `${msg.fps.toFixed(1)} fps`;
  }

  statUtc.textContent  = fmtTime(new Date().toISOString());
  statLast.textContent = fmtTime(new Date().toISOString());

  lastFrameTime = now;
});
