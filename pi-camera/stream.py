"""
pi-camera/stream.py
Raspberry Pi 5 + Camera Module v2 (IMX219) — Bookworm / picamera2
Streams JPEG frames over WebSocket to the relay server.

Optimisations vs. generic version
──────────────────────────────────
• Camera v2 is fixed-focus  → AfMode removed (was causing control errors)
• YUV420 capture + numpy→JPEG encode is faster than RGB888 + capture_file
  on the Pi 5 ISP pipeline (avoids a full colour-space conversion on the CPU)
• Sensor binned mode (1640×1232) → scale to 960×640 in hardware via the ISP,
  keeping full FoV and reducing noise compared to a centre-crop
• Pi 5 DMA buffer queue (buffer_count=4) prevents dropped frames under load
• NoiseReduction set to Fast — good quality, low latency (HighQuality adds ~8 ms)
• Capture runs in a ThreadPoolExecutor so the asyncio loop is never blocked
• Exponential back-off on reconnect to avoid hammering the server

Requirements: see requirements.txt
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
from picamera2 import Picamera2
from libcamera import controls

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [PI-CAM] %(levelname)s — %(message)s",
)
log = logging.getLogger(__name__)

# ── Constants ─────────────────────────────────────────────────────────────────
OUTPUT_W = 960
OUTPUT_H = 640

# Camera v2 (IMX219) binned sensor mode — keeps full FoV, ISP scales to output
SENSOR_W = 1640
SENSOR_H = 1232

# Maximum reconnect wait (seconds)
MAX_BACKOFF = 30


# ── Camera helper ─────────────────────────────────────────────────────────────
def build_camera(fps: int) -> Picamera2:
    """
    Configure picamera2 for Pi 5 + Camera Module v2 (IMX219).

    Key choices
    ───────────
    • YUV420 main stream  — native ISP output, zero-copy to numpy
    • buffer_count=4      — smoother capture under Python GC pauses
    • NoiseReductionMode.Fast — ~2 ms vs ~10 ms for HighQuality
    • Camera v2 is fixed-focus: no AfMode control
    """
    cam = Picamera2()

    frame_us = int(1_000_000 / fps)

    config = cam.create_video_configuration(
        # Ask ISP to output our target size in YUV420 (native, fast)
        main={
            "size":   (OUTPUT_W, OUTPUT_H),
            "format": "YUV420",
        },
        # Hint sensor to use binned 1640×1232 mode (full FoV, 2×2 bin)
        # ISP scales down instead of centre-cropping full 3280×2464
        raw={
            "size":   (SENSOR_W, SENSOR_H),
            "format": "SRGGB10_CSI2P",
        },
        buffer_count=4,
        queue=True,
        controls={
            "FrameDurationLimits": (frame_us, frame_us),
            "AeExposureMode":      controls.AeExposureModeEnum.Normal,
            "NoiseReductionMode":  controls.draft.NoiseReductionModeEnum.Fast,
            "AwbMode":             controls.AwbModeEnum.Auto,
            # IMX219 is slightly soft at this scale — small sharpness boost
            "Sharpness":           1.5,
            "Contrast":            1.0,
        },
    )
    cam.configure(config)
    cam.start()
    log.info(
        "Camera v2 ready: output=%dx%d  sensor=%dx%d  target_fps=%d",
        OUTPUT_W, OUTPUT_H, SENSOR_W, SENSOR_H, fps,
    )
    return cam


def capture_jpeg(cam: Picamera2, quality: int) -> Optional[bytes]:
    """
    Capture one YUV420 frame and encode to JPEG via OpenCV.
    YUV420→BGR on the Pi 5 CPU is faster than RGB888 through the full ISP path.
    """
    frame = cam.capture_array("main")      # shape: (H*3//2, W) uint8
    if frame is None or frame.size == 0:
        return None

    bgr = cv2.cvtColor(frame, cv2.COLOR_YUV420p2BGR)
    ok, buf = cv2.imencode(
        ".jpg",
        bgr,
        [cv2.IMWRITE_JPEG_QUALITY, quality,
         cv2.IMWRITE_JPEG_OPTIMIZE, 1],
    )
    return buf.tobytes() if ok else None


# ── Streaming loop ─────────────────────────────────────────────────────────────
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
                log.info("Connected — %d fps  quality=%d", fps, quality)
                await ws.send(
                    '{"type":"hello","role":"camera","model":"v2","platform":"pi5"}'
                )
                backoff = 2  # reset on successful connect

                while True:
                    t0 = time.monotonic()

                    # Capture in thread — keeps asyncio loop responsive
                    jpeg_bytes = await loop.run_in_executor(
                        pool, capture_jpeg, cam, quality
                    )

                    if jpeg_bytes is None:
                        log.warning("Bad frame — skipping")
                        await asyncio.sleep(frame_interval)
                        continue

                    frame_b64 = base64.b64encode(jpeg_bytes).decode()
                    payload = (
                        f'{{"type":"frame",'
                        f'"ts":{time.time():.3f},'
                        f'"data":"{frame_b64}"}}'
                    )
                    await ws.send(payload)

                    elapsed = time.monotonic() - t0
                    await asyncio.sleep(max(0.0, frame_interval - elapsed))

        except (websockets.ConnectionClosed, OSError) as exc:
            log.warning("Connection lost (%s). Reconnecting in %d s …", exc, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)
        except Exception as exc:
            log.error("Unexpected error: %s. Retrying in %d s …", exc, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)


# ── Entry point ───────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pi 5 + Camera Module v2 WebSocket streamer"
    )
    parser.add_argument("--server",  default="ws://10.0.0.8:8765")
    parser.add_argument("--fps",     type=int, default=30,
                        help="Target frame rate (default: 30, max stable ~60)")
    parser.add_argument("--quality", type=int, default=75,
                        help="JPEG quality 1-100 (default: 75)")
    args = parser.parse_args()

    asyncio.run(stream_loop(args.server, args.fps, args.quality))


if __name__ == "__main__":
    main()
