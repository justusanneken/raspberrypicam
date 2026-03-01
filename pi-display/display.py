"""
pi-display/display.py
Raspberry Pi (display unit) — configures the 960×540 framebuffer/display
and launches Chromium in kiosk mode pointed at the stream server.

This script:
  1. Optionally sets the HDMI / DSI output to 960×540 via tvservice / fbset
     (skip with --no-config if the display is already correct).
  2. Hides the mouse cursor (unclutter).
  3. Kills any stale Chromium instances.
  4. Opens Chromium in full-screen kiosk mode.
  5. Monitors the browser process and restarts it on crash.

Requirements: see requirements.txt
Usage:
    python display.py --server http://YOUR_SERVER_IP:5000 [--no-config]
"""

import argparse
import logging
import os
import subprocess
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [DISPLAY] %(levelname)s — %(message)s",
)
log = logging.getLogger(__name__)

SCREEN_W = 960
SCREEN_H = 640

# Chromium binary locations (in order of preference)
CHROMIUM_CANDIDATES = [
    "chromium-browser",
    "chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/chromium",
]

CHROMIUM_FLAGS = [
    "--kiosk",
    "--noerrdialogs",
    "--disable-infobars",
    "--disable-translate",
    "--no-first-run",
    "--fast",
    "--fast-start",
    "--disable-features=TranslateUI",
    "--disk-cache-dir=/dev/null",
    "--overscroll-history-navigation=0",
    "--disable-pinch",
    f"--window-size={SCREEN_W},{SCREEN_H}",
    "--window-position=0,0",
    "--start-fullscreen",
    "--autoplay-policy=no-user-gesture-required",
    "--use-gl=egl",
]


def find_chromium() -> str:
    """Return the first Chromium binary found on the system."""
    for candidate in CHROMIUM_CANDIDATES:
        try:
            result = subprocess.run(
                ["which", candidate], capture_output=True, text=True, check=False
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except FileNotFoundError:
            continue
    raise RuntimeError(
        "Chromium not found. Install via: sudo apt install chromium-browser"
    )


def configure_display() -> None:
    """Attempt to force the display to 960×540 using fbset."""
    log.info("Configuring framebuffer to %dx%d …", SCREEN_W, SCREEN_H)
    try:
        subprocess.run(
            ["fbset", "-xres", str(SCREEN_W), "-yres", str(SCREEN_H),
             "-vxres", str(SCREEN_W), "-vyres", str(SCREEN_H), "-depth", "24"],
            check=True,
            capture_output=True,
        )
        log.info("fbset OK")
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        log.warning("fbset failed (%s) — display config skipped", exc)


def hide_cursor() -> None:
    """Launch unclutter to hide the mouse pointer."""
    try:
        subprocess.Popen(
            ["unclutter", "-idle", "0", "-root"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.info("Cursor hidden via unclutter")
    except FileNotFoundError:
        log.warning(
            "unclutter not found — install via: sudo apt install unclutter"
        )


def kill_stale_chromium() -> None:
    """Kill any left-over Chromium processes."""
    try:
        subprocess.run(["pkill", "-f", "chromium"], check=False, capture_output=True)
        time.sleep(1)
    except Exception:
        pass


def launch_kiosk(url: str, chromium_bin: str) -> subprocess.Popen:
    """Start Chromium in kiosk mode and return its Popen handle."""
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")

    cmd = [chromium_bin, *CHROMIUM_FLAGS, url]
    log.info("Launching: %s", " ".join(cmd))
    return subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )


def watchdog_loop(url: str, chromium_bin: str, restart_delay: int = 5) -> None:
    """Run Chromium and restart it automatically if it exits."""
    while True:
        proc = launch_kiosk(url, chromium_bin)
        log.info("Chromium started (PID %d)", proc.pid)
        code = proc.wait()
        log.warning(
            "Chromium exited with code %d. Restarting in %d s …",
            code,
            restart_delay,
        )
        time.sleep(restart_delay)
        kill_stale_chromium()


def main() -> None:
    parser = argparse.ArgumentParser(description="Pi kiosk display launcher")
    parser.add_argument(
        "--server",
        default="http://localhost:5000",
        help="Stream server URL (default: http://localhost:5000)",
    )
    parser.add_argument(
        "--no-config",
        action="store_true",
        help="Skip display resolution configuration",
    )
    parser.add_argument(
        "--restart-delay",
        type=int,
        default=5,
        help="Seconds before restarting Chromium after a crash (default: 5)",
    )
    args = parser.parse_args()

    if not args.no_config:
        configure_display()

    hide_cursor()
    kill_stale_chromium()

    try:
        chromium = find_chromium()
        log.info("Using Chromium at: %s", chromium)
    except RuntimeError as exc:
        log.error(str(exc))
        sys.exit(1)

    log.info("Opening dashboard at %s", args.server)
    watchdog_loop(args.server, chromium, args.restart_delay)


if __name__ == "__main__":
    main()
