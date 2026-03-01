# CAM Stream — Setup Guide

Three-component system:

| Folder | Role | Hardware |
|---|---|---|
| `pi-camera/` | Captures and streams video | Raspberry Pi + Camera Module |
| `server/` | Relay server + web dashboard | Any Linux/Mac/PC on the same network |
| `pi-display/` | Kiosk browser display | Raspberry Pi + 960×640 screen |

---

## Prerequisites — All Devices

- Python 3.11+
- Devices on the **same local network**
- Note the **IP address of the server machine** — you'll use it throughout (`SERVER_IP`)

---

## 1 — Server

### 1.1 Install dependencies

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 1.2 Run the server

```bash
python server.py --host 0.0.0.0 --port 5000 --ws-port 8765
```

The server now listens on two ports:

| Port | Purpose |
|---|---|
| `5000` | Web dashboard (HTTP + Socket.IO) |
| `8765` | Camera WebSocket intake |

### 1.3 Verify

Open a browser on the same machine and go to `http://localhost:5000`.  
You should see the dark dashboard with an "Waiting for stream…" overlay.

### 1.4 (Optional) Run as a systemd service

```bash
sudo nano /etc/systemd/system/cam-server.service
```

```ini
[Unit]
Description=CAM Stream Server
After=network-online.target

[Service]
User=pi
WorkingDirectory=/path/to/cam/server
ExecStart=/path/to/cam/server/.venv/bin/python server.py --host 0.0.0.0 --port 5000 --ws-port 8765
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cam-server
```

---

## 2 — Camera Pi (`pi-camera/`)

### 2.1 Enable the camera

```bash
sudo raspi-config
# Interface Options → Camera → Enable
sudo reboot
```

### 2.2 Install system dependencies

```bash
sudo apt update
sudo apt install -y python3-picamera2 python3-pip
```

### 2.3 Install Python dependencies

```bash
cd pi-camera
python3 -m venv .venv --system-site-packages   # --system-site-packages gives access to picamera2
source .venv/bin/activate
pip install -r requirements.txt
```

### 2.4 Start streaming

Replace `SERVER_IP` with the actual IP address of your server machine.

```bash
python stream.py --server ws://SERVER_IP:8765 --fps 30 --quality 80
```

Options:

| Flag | Default | Description |
|---|---|---|
| `--server` | `ws://localhost:8765` | WebSocket URL of the relay server |
| `--fps` | `30` | Target capture frame rate |
| `--quality` | `80` | JPEG quality (1–100) |

The script reconnects automatically on network drops.

### 2.5 (Optional) Systemd service

```bash
sudo nano /etc/systemd/system/cam-stream.service
```

```ini
[Unit]
Description=CAM Pi Camera Streamer
After=network-online.target

[Service]
User=pi
WorkingDirectory=/home/pi/cam/pi-camera
ExecStart=/home/pi/cam/pi-camera/.venv/bin/python stream.py --server ws://SERVER_IP:8765
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cam-stream
```

---

## 3 — Display Pi (`pi-display/`)

### 3.1 Install system dependencies

```bash
sudo apt update
sudo apt install -y chromium-browser unclutter xorg openbox
```

### 3.2 Configure X to auto-start (headless display)

Edit `/etc/lightdm/lightdm.conf` (or use `raspi-config` → Desktop Autologin):

```
autologin-user=pi
```

### 3.3 Disable screen blanking permanently

Add to `/home/pi/.config/openbox/autostart` (create if missing):

```bash
xset s off
xset -dpms
xset s noblank
```

### 3.4 Run the kiosk

```bash
cd pi-display
chmod +x kiosk.sh
./kiosk.sh --server http://SERVER_IP:5000
```

Or directly with Python:

```bash
python display.py --server http://SERVER_IP:5000
```

Options:

| Flag | Default | Description |
|---|---|---|
| `--server` | `http://localhost:5000` | Dashboard URL |
| `--no-config` | off | Skip framebuffer resolution setup |
| `--restart-delay` | `5` | Seconds before restarting Chromium after a crash |

### 3.5 (Optional) Systemd service

```bash
sudo nano /etc/systemd/system/cam-display.service
```

```ini
[Unit]
Description=CAM Kiosk Display
After=graphical-session.target

[Service]
User=pi
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
WorkingDirectory=/home/pi/cam/pi-display
ExecStart=/home/pi/cam/pi-display/kiosk.sh --server http://SERVER_IP:5000
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-session.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cam-display
```

---

## Network Overview

```
┌─────────────────────┐        WebSocket ws://:8765
│   Raspberry Pi      │  ─────────────────────────────────►  ┌──────────────┐
│   (Camera)          │                                       │              │
│   pi-camera/        │                                       │    Server    │
└─────────────────────┘                                       │  server/     │
                                                              │              │
┌─────────────────────┐        HTTP + Socket.IO :5000         │              │
│   Raspberry Pi      │  ◄─────────────────────────────────   └──────────────┘
│   (Display)         │
│   pi-display/       │
└─────────────────────┘
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Dashboard shows "Waiting for stream…" | Camera Pi not connected — check `--server` URL and firewall on ports 8765/5000 |
| `picamera2` import error | Run with `--system-site-packages` venv or `sudo apt install python3-picamera2` |
| Chromium won't open | Ensure `DISPLAY=:0` is set and X is running — check `echo $DISPLAY` |
| `fbset` warning on display Pi | Harmless if screen is already 960×640; pass `--no-config` to silence it |
| High latency | Lower `--fps` or `--quality`; check network bandwidth with `iperf3` |
| Server crash on start | Confirm ports 5000 and 8765 are free: `lsof -i :5000 -i :8765` |
