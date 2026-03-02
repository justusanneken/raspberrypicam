"""
pi-camera/stream.py
Raspberry Pi 5 + Camera Module v2 (IMX219) on Bookworm.
Captures YUV420 frames, encodes to JPEG with OpenCV, streams over WebSocket.

Usage:
    python stream.py [--server ws://10.0.0.8:8765] [--fps 30] [--quality 75]
"""

import argparse
import asyncio
import base64
import concurrent.futures
import logging
import time
from typing import Optional

import cv2
import websockets
from libcamera import controls
from picamera2 import Picamera2

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [PI-CAM] %(levelname)s — %(message)s",
)
log = logging.getLogger(__name__)

# ── Tuning for Pi 5 + IMX219 (Camera v2) ─────────────────────────────────────
OUTPUT_W = 960
OUTPUT_H = 640

# 2×2 binned mode — full field of view, ISP scales to OUTPUT size in hardware.
# Full res (3280×2464) would waste ISP bandwidth for a 960×640 output.
SENSOR_W = 1640
SENSOR_H = 1232

MAX_RECONNECT_WAIT = 30   # seconds


def build_camera(fps: int) -> Picamera2:
    """
    Configure picamera2 for Pi 5 + IMX219.

    Notes
    ─────
    • YUV420 format   — native ISP output, fastest path to numpy/OpenCV
    • buffer_count=4  — prevents dropped frames under Python GC pressure
    • NoiseReduction.Fast — ~2 ms latency vs ~10 ms for HighQuality
    • No AfMode       — IMX219 is fixed-focus (setting it causes a control error)
    • Sharpness 1.5   — IMX219 is slightly soft at this scale, small boost helps
    """
    cam = Picamera2()
    frame_us = int(1_000_000 / fps)

    config = cam.create_video_configuration(
        main={"size": (OUTPUT_W, OUTPUT_H), "format": "YUV420"},
        raw={"size": (SENSOR_W, SENSOR_H), "format": "SRGGB10_CSI2P"},
        buffer_count=4,
        queue=True,
        controls={
            "FrameDurationLimits": (frame_us, frame_us),
            "AeExposureMode":      controls.AeExposureModeEnum.Normal,
            "NoiseReductionMode":  controls.draft.NoiseReductionModeEnum.Fast,
            "AwbMode":             controls.AwbModeEnum.Auto,
            "Sharpness":           1.5,
            "Contrast":            1.0,
        },
    )
    cam.configure(config)
    cam.start()
    log.info(
        "Camera ready  output=%dx%d  sensor=%dx%d  fps=%d",
        OUTPUT_W, OUTPUT_H, SENSOR_W, SENSOR_H, fps,
    )
    return cam


def capture_jpeg(cam: Picamera2, quality: int) -> Optional[bytes]:
    """
    Grab one YUV420 frame and encode as JPEG.
    Running in a ThreadPoolExecutor keeps the asyncio loop unblocked.
    """
    frame = cam.capture_array("main")   # (H*3//2, W) uint8
    if frame is None or frame.size == 0:
        return None

    bgr = cv2.cvtColor(frame, cv2.COLOR_YUV420p2BGR)
    ok, buf = cv2.imencode(
        ".jpg", bgr,
        [cv2.IMWRITE_JPEG_QUALITY, quality, cv2.IMWRITE_JPEG_OPTIMIZE, 1],
    )
    return buf.tobytes() if ok else None


async def stream_loop(server_url: str, fps: int, quality: int) -> None:
    frame_interval = 1.0 / fps
    cam  = build_camera(fps)
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="cam")
    loop = asyncio.get_running_loop()
    backoff = 2

    while True:
        try:
            log.info("Connecting to %s …", server_url)
            async with websockets.connect(
                server_url,
                ping_interval=10,
                ping_timeout=20,
                max_size=None,
            ) as ws:
                log.info("Connected — streaming %d fps  quality=%d", fps, quality)
                await ws.send(
                    '{"type":"hello","role":"camera",'
                    '"model":"v2","platform":"pi5"}'
                )
                backoff = 2  # reset on success

                while True:
                    t0 = time.monotonic()

                    jpeg = await loop.run_in_executor(pool, capture_jpeg, cam, quality)
                    if jpeg is None:
                        log.warning("Empty frame — skipping")
                        await asyncio.sleep(frame_interval)
                        continue

                    payload = (
                        f'{{"type":"frame",'
                        f'"ts":{time.time():.3f},'
                        f'"data":"{base64.b64encode(jpeg).decode()}"}}'
                    )
                    await ws.send(payload)

                    await asyncio.sleep(max(0.0, frame_interval - (time.monotonic() - t0)))

        except (websockets.ConnectionClosed, OSError) as exc:
            log.warning("Disconnected (%s) — retry in %ds", exc, backoff)
        except Exception as exc:
            log.error("Error: %s — retry in %ds", exc, backoff)

        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, MAX_RECONNECT_WAIT)


def main() -> None:
    parser = argparse.ArgumentParser(description="Pi 5 Camera v2 WebSocket streamer")
    parser.add_argument("--server",  default="ws://10.0.0.8:8765",
                        help="Relay server WebSocket URL")
    parser.add_argument("--fps",     type=int, default=30,
                        help="Target frame rate (default 30, stable up to ~60)")
    parser.add_argument("--quality", type=int, default=75,
                        help="JPEG quality 1-100 (default 75)")
    args = parser.parse_args()
    asyncio.run(stream_loop(args.server, args.fps, args.quality))


if __name__ == "__main__":
    main()

