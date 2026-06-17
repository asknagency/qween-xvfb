# qween-xvfb

Production render server for QweenApp projects.
Uses **Xvfb** (virtual display) + **Chromium** (non-headless) + **FFmpeg x11grab**
to record animations including `<video>` elements with correct z-order and GSAP transforms.

## Why this exists

The CodeSandbox-hosted `qween-ffmpeg` service uses headless Chromium + Playwright
frame-by-frame seeking. That approach works well for SVG-only projects but requires
a software compositing workaround (SwiftShader or sandwich compositing) to capture
`<video>` pixels correctly.

This server runs on a beefier machine (4+ CPUs, 8+ GB RAM) and uses the real
Chromium compositor — video, WebGL, CSS filters, and all GSAP transforms including
MotionPath just work, no special treatment needed.

## Architecture

```
project.zip  →  FastAPI /jobs/render-project
                    │
                    ├─ Write project ZIP to projects/
                    ├─ Acquire virtual display from pool (:99, :100, …)
                    ├─ Launch Xvfb on display :N
                    ├─ Launch Chromium --app=QweenRender.html?autoplay=1
                    ├─ Poll __qween_ready via CDP
                    ├─ Start FFmpeg x11grab capture → capture.mp4 (lossless)
                    ├─ Trigger masterTl.play(0) via CDP
                    ├─ Wait duration + 1.5s buffer
                    ├─ Stop FFmpeg, kill Chromium, kill Xvfb
                    ├─ Re-encode capture.mp4 → output.(mp4|mov|webm)
                    └─ Release display
```

## Render modes comparison

| | qween-ffmpeg (SwiftShader) | qween-ffmpeg (sandwich) | qween-xvfb |
|---|---|---|---|
| Video compositing | Software GPU | FFmpeg overlay | Real compositor |
| GSAP video transforms | ✅ | ❌ (position only) | ✅ |
| z-order correctness | ✅ | ✅ (3-pass) | ✅ |
| Deterministic FPS | ✅ (seek-based) | ✅ (seek-based) | ⚠️ (real-time) |
| Render speed | Medium | Slow (3× passes) | Real-time minimum |
| Hardware required | 2 CPU / 4 GB | 2 CPU / 4 GB | 4+ CPU / 8+ GB |
| Concurrent jobs | Queue (1 at a time) | Queue (1 at a time) | Display pool |

## API

### POST /jobs/render-project

Accepts a QweenApp project ZIP as `multipart/form-data`.

**Form fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | file | required | Project `.zip` or bare `project.json` |
| `fps` | float | 30 | Output frames per second |
| `crf` | int | 18 | Quality (lower = better, 0 = lossless) |
| `format` | string | mp4 | Output format: `mp4`, `mov`, `webm` |
| `start_time` | float | 0 | Timeline start (seconds) |
| `end_time` | float | 0 | Timeline end (0 = auto-detect from tweens) |
| `stage_width` | int | 1920 | Output width |
| `stage_height` | int | 1080 | Output height |

**Response:**
```json
{
  "job_id": "abc123",
  "status": "queued",
  "poll_url": "/jobs/abc123/status",
  "renderer": "xvfb"
}
```

### GET /jobs/{job_id}/status

Poll for job progress.

```json
{
  "id": "abc123",
  "status": "processing",   // queued | processing | done | error
  "progress": 45,           // 0–100
  "message": "Recording… 4.2s / 9.6s"
}
```

### GET /jobs/{job_id}/download

Download the finished video file once `status == "done"`.

### GET /health

Returns `{"status": "ok"}` if Xvfb, Chromium, and FFmpeg are all available.
Returns `{"status": "degraded"}` with details if any dependency is missing.

## Requirements

- **4+ CPU cores** — 2 for FFmpeg x11grab encode, 1+ for Chromium compositor, 1 for API
- **8+ GB RAM** — Chromium non-headless uses ~500MB, FFmpeg ~200MB, API ~150MB
- **Xvfb** (`apt install xvfb`)
- **Chromium** (`apt install chromium` or `google-chrome-stable`)
- **FFmpeg** built with `--enable-x11grab` (`apt install ffmpeg` on Ubuntu includes this)
- **Python 3.12+**
- **Node.js 18+** (for the static file server)

## Quick start (bare metal / VM)

```bash
# Install system deps (Ubuntu 22.04+)
sudo apt install -y xvfb chromium ffmpeg python3.12 python3.12-venv nodejs

# Clone and install
git clone https://github.com/asknagency/qween-xvfb.git
cd qween-xvfb
python3 -m venv venv && source venv/bin/activate
pip install -r apps/api/requirements.txt
npm install --prefix apps/app

# Run
node apps/app/server.js &
uvicorn apps.api.main:app --host 0.0.0.0 --port 8000
```

## Docker

```bash
docker build -t qween-xvfb .
docker run -p 8000:8000 \
  -e MAX_CONCURRENT_RENDERS=2 \
  --shm-size=2g \
  qween-xvfb
```

> `--shm-size=2g` is required — Chromium uses `/dev/shm` for GPU memory buffers.
> Without it Chromium crashes or renders black frames.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CHROMIUM_BIN` | `chromium` | Path/name of Chromium binary |
| `RENDERER_URL` | `http://localhost:3001` | URL of the static file server |
| `MAX_CONCURRENT_RENDERS` | `2` | Number of parallel render jobs (= virtual display pool size) |
| `WORK_DIR` | `/tmp/qween_xvfb` | Working directory for frame captures |
| `ASSETS_DIR` | `apps/api/assets` | Persistent asset store |

## Known limitations

- **Real-time only** — a 30s animation takes at least 30s to render (plus encode time)
- **Frame timing** — x11grab captures at wall-clock rate; under CPU pressure frames may
  be duplicated or dropped. Use a dedicated machine with headroom.
- **No GIF output** — GIF requires frame-by-frame seeking which is incompatible with
  real-time capture. Use `qween-ffmpeg` for GIF.
- **Audio** — not yet implemented. PulseAudio virtual sink + FFmpeg `-f pulse` capture
  would add this cleanly.
