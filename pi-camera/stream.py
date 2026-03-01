"""
pi-camera/stream.py
Raspberry Pi (camera unit) — captures frames with picamera2 and streams
them as base64-encoded JPEGs over a WebSocket to the central server.

Requirements: see requirements.txt
Usage:
    python stream.py --server ws://YOUR_SERVER_IP:8765 --fps 30 --quality 80
"""

import argparse
import asyncio
import base64
import io
import logging
import time

import websockets
from picamera2 import Picamera2
from libcamera import controls

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [CAM] %(levelname)s — %(message)s",
)
log = logging.getLogger(__name__)

FRAME_WIDTH = 960
FRAME_HEIGHT = 640


def build_camera(fps: int) -> Picamera2:
    cam = Picamera2()
    config = cam.create_video_configuration(
        main={"size": (FRAME_WIDTH, FRAME_HEIGHT), "format": "RGB888"},
        controls={
            "FrameDurationLimits": (int(1e6 // fps), int(1e6 // fps)),
            "AfMode": controls.AfModeEnum.Continuous,
        },
    )
    cam.configure(config)
    cam.start()
    log.info("Camera started at %dx%d @ %d fps", FRAME_WIDTH, FRAME_HEIGHT, fps)
    return cam


async def stream_loop(server_url: str, fps: int, quality: int) -> None:
    frame_interval = 1.0 / fps
    cam = build_camera(fps)

    while True:
        try:
            log.info("Connecting to server at %s …", server_url)
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

                    # Capture JPEG frame
                    buf = io.BytesIO()
                    cam.capture_file(buf, format="jpeg")
                    buf.seek(0)
                    frame_b64 = base64.b64encode(buf.read()).decode()

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
            log.error("Unexpected error: %s. Reconnecting in 5 s …", exc)
            await asyncio.sleep(5)


def main() -> None:
    parser = argparse.ArgumentParser(description="Pi Camera WebSocket streamer")
    parser.add_argument(
        "--server",
        default="ws://localhost:8765",
        help="WebSocket server URL (default: ws://localhost:8765)",
    )
    parser.add_argument(
        "--fps", type=int, default=30, help="Target frames per second (default: 30)"
    )
    parser.add_argument(
        "--quality",
        type=int,
        default=80,
        help="JPEG quality 1-100 (default: 80)",
    )
    args = parser.parse_args()

    asyncio.run(stream_loop(args.server, args.fps, args.quality))


if __name__ == "__main__":
    main()
