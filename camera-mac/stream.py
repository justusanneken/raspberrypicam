"""
camera-mac/stream.py
macOS test streamer — captures from the Mac's built-in webcam (or any
attached camera) using OpenCV and streams JPEG frames over WebSocket to
the relay server, using the exact same protocol as the Pi camera.

Requirements: see requirements.txt
Usage:
    python stream.py [--server ws://10.0.0.8:8765] [--fps 30] [--quality 80] [--device 0]
"""

import argparse
import asyncio
import base64
import logging
import time

import cv2
import websockets

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [MAC-CAM] %(levelname)s — %(message)s",
)
log = logging.getLogger(__name__)

FRAME_WIDTH  = 960
FRAME_HEIGHT = 640


def open_camera(device: int) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(device)
    if not cap.isOpened():
        raise RuntimeError(
            f"Could not open camera device {device}. "
            "Try --device 1 if you have multiple cameras."
        )
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  FRAME_WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_HEIGHT)
    log.info(
        "Camera opened: device=%d  actual=%dx%d",
        device,
        int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
        int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
    )
    return cap


async def stream_loop(server_url: str, fps: int, quality: int, device: int) -> None:
    frame_interval = 1.0 / fps
    cap = open_camera(device)

    encode_params = [cv2.IMWRITE_JPEG_QUALITY, quality]

    while True:
        try:
            log.info("Connecting to %s …", server_url)
            async with websockets.connect(
                server_url,
                ping_interval=10,
                ping_timeout=20,
                max_size=None,
            ) as ws:
                log.info("Connected. Streaming …")
                await ws.send('{"type":"hello","role":"camera"}')

                while True:
                    t0 = time.monotonic()

                    ret, frame = cap.read()
                    if not ret:
                        log.warning("Failed to grab frame — skipping")
                        await asyncio.sleep(frame_interval)
                        continue

                    # Resize if the camera couldn't honour our request
                    h, w = frame.shape[:2]
                    if w != FRAME_WIDTH or h != FRAME_HEIGHT:
                        frame = cv2.resize(frame, (FRAME_WIDTH, FRAME_HEIGHT))

                    ok, buf = cv2.imencode(".jpg", frame, encode_params)
                    if not ok:
                        continue

                    frame_b64 = base64.b64encode(buf.tobytes()).decode()
                    payload = (
                        f'{{"type":"frame",'
                        f'"ts":{time.time():.3f},'
                        f'"data":"{frame_b64}"}}'
                    )
                    await ws.send(payload)

                    elapsed = time.monotonic() - t0
                    await asyncio.sleep(max(0.0, frame_interval - elapsed))

        except (websockets.ConnectionClosed, OSError) as exc:
            log.warning("Connection lost (%s). Reconnecting in 3 s …", exc)
            await asyncio.sleep(3)
        except Exception as exc:
            log.error("Unexpected error: %s. Retrying in 5 s …", exc)
            await asyncio.sleep(5)


def main() -> None:
    parser = argparse.ArgumentParser(description="macOS webcam WebSocket streamer")
    parser.add_argument("--server",  default="ws://10.0.0.8:8765")
    parser.add_argument("--fps",     type=int, default=30)
    parser.add_argument("--quality", type=int, default=80)
    parser.add_argument("--device",  type=int, default=0,
                        help="Camera device index (default: 0 = built-in FaceTime camera)")
    args = parser.parse_args()

    asyncio.run(stream_loop(args.server, args.fps, args.quality, args.device))


if __name__ == "__main__":
    main()
