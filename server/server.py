"""
server/server.py
Central relay server — receives the camera WebSocket stream, relays frames
to all connected browser clients via Socket.IO, and serves the dashboard.

Requirements: see requirements.txt
Usage:
    python server.py [--host 0.0.0.0] [--port 5000] [--ws-port 8765]
"""

import argparse
import asyncio
import base64
import json
import logging
import threading
import time
from collections import deque
from datetime import datetime, timezone

import websockets
from flask import Flask, render_template
from flask_socketio import SocketIO

# ── Logging ──────────────────────────────────────────────────────────────────
class _ColorFormatter(logging.Formatter):
    RESET  = "\033[0m"
    GREY   = "\033[90m"
    CYAN   = "\033[96m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    RED    = "\033[91m"
    BOLD   = "\033[1m"
    LEVEL_COLORS = {
        logging.DEBUG:    GREY,
        logging.INFO:     CYAN,
        logging.WARNING:  YELLOW,
        logging.ERROR:    RED,
        logging.CRITICAL: RED + BOLD,
    }
    def format(self, record):
        color = self.LEVEL_COLORS.get(record.levelno, self.RESET)
        ts    = self.formatTime(record, "%H:%M:%S")
        lvl   = f"{color}{record.levelname:<8}{self.RESET}"
        msg   = record.getMessage()
        return f"  {self.GREY}{ts}{self.RESET}  {lvl}  {msg}"

_handler = logging.StreamHandler()
_handler.setFormatter(_ColorFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler])
log = logging.getLogger(__name__)

# ── Flask / Socket.IO setup ───────────────────────────────────────────────────
app = Flask(__name__)
app.config["SECRET_KEY"] = "cam-stream-secret-change-me"
sio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# ── Shared state ──────────────────────────────────────────────────────────────
stats = {
    "fps": 0.0,
    "connected": False,
    "frame_count": 0,
    "last_seen": None,
}
_frame_times: deque = deque(maxlen=60)          # timestamps of recent frames
_latest_frame: str | None = None                 # base64 JPEG of latest frame


# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


# ── Socket.IO events ──────────────────────────────────────────────────────────
@sio.on("connect")
def on_browser_connect():
    log.info("Browser client connected")
    sio.emit("status", _build_status())
    # Send the most recent frame immediately so the page isn't blank
    if _latest_frame:
        sio.emit("frame", {"data": _latest_frame, "ts": time.time()})


@sio.on("disconnect")
def on_browser_disconnect():
    log.info("Browser client disconnected")


def _build_status() -> dict:
    return {
        "connected": stats["connected"],
        "fps": round(stats["fps"], 1),
        "frame_count": stats["frame_count"],
        "last_seen": stats["last_seen"],
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


def _compute_fps() -> float:
    now = time.monotonic()
    if len(_frame_times) < 2:
        return 0.0
    window = [t for t in _frame_times if now - t < 1.0]
    return float(len(window))


# ── Camera WebSocket receiver (runs in its own asyncio loop / thread) ─────────
async def _camera_ws_server(host: str, ws_port: int) -> None:
    global _latest_frame

    async def handle_camera(ws) -> None:
        global _latest_frame
        remote = ws.remote_address
        log.info("Camera connected from %s", remote)
        stats["connected"] = True
        sio.emit("status", _build_status())

        try:
            async for raw in ws:
                msg = json.loads(raw)

                if msg.get("type") == "frame":
                    frame_b64: str = msg["data"]
                    _latest_frame = frame_b64
                    stats["frame_count"] += 1
                    stats["last_seen"] = datetime.now(timezone.utc).isoformat()
                    _frame_times.append(time.monotonic())
                    stats["fps"] = _compute_fps()

                    sio.emit(
                        "frame",
                        {
                            "data": frame_b64,
                            "ts": msg.get("ts", time.time()),
                            "fps": round(stats["fps"], 1),
                        },
                    )

        except websockets.ConnectionClosed:
            pass
        finally:
            log.warning("Camera disconnected from %s", remote)
            stats["connected"] = False
            sio.emit("status", _build_status())

    async with websockets.serve(handle_camera, host, ws_port):
        log.info("Camera WebSocket listener on ws://%s:%d", host, ws_port)
        await asyncio.Future()   # run forever


def _start_ws_thread(host: str, ws_port: int) -> None:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(_camera_ws_server(host, ws_port))


# ── Entry point ───────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description="Cam-stream relay server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--ws-port", type=int, default=8765)
    args = parser.parse_args()

    ws_thread = threading.Thread(
        target=_start_ws_thread,
        args=(args.host, args.ws_port),
        daemon=True,
    )
    ws_thread.start()

    log.info("Web server on http://%s:%d", args.host, args.port)
    sio.run(app, host=args.host, port=args.port, allow_unsafe_werkzeug=True)


if __name__ == "__main__":
    main()
