"""
qween-xvfb — Production render server
Accepts a QweenApp project ZIP, renders it using Chromium on Xvfb with
FFmpeg x11grab capture, and returns the finished video file.

Requirements: Xvfb, Chromium (non-headless), FFmpeg with x11grab support.
See Dockerfile for exact dependencies.

Architecture:
  - One Xvfb virtual display per concurrent job (display pool :99, :100, …)
  - Chromium launched non-headless against that display
  - FFmpeg x11grab captures the display in real-time during playback
  - Animation plays at real speed via masterTl.play(0)
  - FastAPI returns job_id immediately; poll /jobs/{job_id}/status

Why this works:
  - Chromium with a real display compositor correctly composites <video> frames
  - All GSAP transforms (y, scale, rotation, MotionPath) apply to video nodes
  - z-order is handled by the browser — no sandwich compositing needed
  - Audio (if added later) is captured by FFmpeg via PulseAudio/ALSA
"""

import asyncio
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import aiofiles
from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

# ── App setup ─────────────────────────────────────────────────────────────────
app = FastAPI(title="QweenXvfb Render Server", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

WORK_DIR   = Path(os.environ.get("WORK_DIR", str(Path(tempfile.gettempdir()) / "qween_xvfb")))
WORK_DIR.mkdir(parents=True, exist_ok=True)
ASSETS_DIR = Path(os.environ.get("ASSETS_DIR", Path(__file__).parent / "assets"))
ASSETS_DIR.mkdir(parents=True, exist_ok=True)
PROJECTS_DIR = Path(__file__).parent.parent / "app" / "public" / "projects"
PROJECTS_DIR.mkdir(parents=True, exist_ok=True)

# Static file server for QweenRender.html + project ZIPs
RENDERER_URL = os.environ.get("RENDERER_URL", "http://localhost:3001")

MAX_ZIP_MB        = 500
MAX_VIDEO_MB      = 2048
AUTO_CLEAN_HOURS  = 6
MAX_CONCURRENT    = int(os.environ.get("MAX_CONCURRENT_RENDERS", "2"))

FORMAT_CONFIG = {
    "mp4":  {"ext": ".mp4",  "mime": "video/mp4",      "vcodec": "libx264",    "pix_fmt": "yuv420p"},
    "mov":  {"ext": ".mov",  "mime": "video/quicktime", "vcodec": "libx264",    "pix_fmt": "yuv420p"},
    "webm": {"ext": ".webm", "mime": "video/webm",      "vcodec": "libvpx-vp9", "pix_fmt": "yuv420p"},
}
VALID_FORMATS = set(FORMAT_CONFIG.keys())

ASSET_VIDEO_EXTS   = {".mp4", ".mov", ".webm", ".avi", ".mkv"}
ASSET_FONT_EXTS    = {".woff2", ".woff", ".ttf", ".otf"}
ASSET_ALLOWED_EXTS = ASSET_VIDEO_EXTS | ASSET_FONT_EXTS

_asset_hash_index: Dict[str, str] = {}
_asset_lock = threading.Lock()

# ── Display pool ──────────────────────────────────────────────────────────────
# Each concurrent render gets its own Xvfb virtual display.
# Display numbers start at :99 to avoid conflicts with real displays.
_DISPLAY_START = 99
_display_pool  = list(range(_DISPLAY_START, _DISPLAY_START + MAX_CONCURRENT))
_display_lock  = threading.Lock()
_display_in_use: set[int] = set()


def _acquire_display() -> int:
    """Block until a display number is available, then reserve it."""
    while True:
        with _display_lock:
            available = [d for d in _display_pool if d not in _display_in_use]
            if available:
                disp = available[0]
                _display_in_use.add(disp)
                return disp
        time.sleep(0.5)


def _release_display(disp: int):
    with _display_lock:
        _display_in_use.discard(disp)


# ── Job state ─────────────────────────────────────────────────────────────────
_jobs: Dict[str, dict] = {}
_jobs_lock = threading.Lock()


def _job_init(job_id: str, label: str = ""):
    with _jobs_lock:
        _jobs[job_id] = {
            "id": job_id, "label": label, "status": "queued",
            "progress": 0, "message": "Queued", "created_at": time.time(),
            "output": None, "size_mb": None, "format": None,
        }


def _job_update(job_id: str, **kw):
    with _jobs_lock:
        if job_id in _jobs:
            _jobs[job_id].update(kw)


def new_job(label: str = "") -> tuple[str, Path]:
    job_id  = str(uuid.uuid4())
    job_dir = WORK_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    _job_init(job_id, label)
    return job_id, job_dir


# ── FFmpeg helpers ────────────────────────────────────────────────────────────
_ffmpeg_sem = threading.Semaphore(MAX_CONCURRENT)


def run_ffmpeg(args: list[str]) -> tuple[int, str, str]:
    """Run ffmpeg with the given args. Returns (returncode, stdout, stderr)."""
    cmd = ["ffmpeg", "-y", *args]
    with _ffmpeg_sem:
        result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def output_path_for(job_dir: Path, fmt: str) -> Path:
    return job_dir / f"output{FORMAT_CONFIG[fmt]['ext']}"


# ── Asset store ───────────────────────────────────────────────────────────────
def _resolve_asset_file(asset_id: str) -> Path | None:
    asset_dir = ASSETS_DIR / asset_id
    if not asset_dir.is_dir():
        return None
    for p in asset_dir.iterdir():
        if p.name != "meta.json" and p.suffix.lower() in ASSET_VIDEO_EXTS:
            return p
    return None


# ── Duration estimation (mirrors qween-ffmpeg logic) ─────────────────────────
def _estimate_timeline_end(tweens: list) -> float:
    seq_point  = 0.0
    prev_start = 0.0
    max_end    = 0.0
    for t in tweens:
        tv  = t.get("timingVars") or {}
        dur = float(tv.get("duration", 0) or 0)
        pos = t.get("position") if t.get("position") is not None else tv.get("position")
        if pos is None or pos == "" or pos == ">":
            start = seq_point
        elif pos == "<":
            start = prev_start
        else:
            try:
                start = float(str(pos))
            except ValueError:
                start = seq_point
        end = start + dur
        if end > max_end:
            max_end = end
        if end > seq_point:
            seq_point = end
        prev_start = start
    return max_end if max_end > 0 else 5.0


# ── Xvfb + Chromium + FFmpeg render ──────────────────────────────────────────
def _run_xvfb_render(job_id: str, job_dir: Path, payload: dict,
                      fmt: str, fps: float, crf: int):
    """
    Full Xvfb render pipeline:
      1. Acquire a virtual display number from the pool
      2. Launch Xvfb on that display
      3. Write project ZIP to PROJECTS_DIR
      4. Launch Chromium (non-headless) pointing to QweenRender.html
      5. Poll __qween_ready via CDP (xdotool / chromium --remote-debugging-port)
      6. Start FFmpeg x11grab capture
      7. Trigger masterTl.play(0) via CDP
      8. Wait for __qween_done signal or animation duration + buffer
      9. Stop FFmpeg, kill Chromium, kill Xvfb
      10. Encode captured stream to final format
      11. Release display
    """
    stage_w = payload.get("stageWidth", 1920)
    stage_h = payload.get("stageHeight", 1080)
    end_time   = payload.get("endTime", 0) or 0
    start_time = payload.get("startTime", 0) or 0
    duration   = end_time - start_time
    if duration <= 0:
        tweens   = payload.get("tweens", [])
        duration = _estimate_timeline_end(tweens)

    disp = _acquire_display()
    xvfb_proc     = None
    chromium_proc = None
    ffmpeg_proc   = None
    project_zip_path = PROJECTS_DIR / f"{job_id}.zip"

    try:
        _job_update(job_id, status="processing", message="Starting virtual display…", progress=2)

        # ── 1. Write project ZIP ─────────────────────────────────────────────
        import io as _io
        zip_buf = _io.BytesIO()
        with zipfile.ZipFile(zip_buf, "w", zipfile.ZIP_DEFLATED) as _zf:
            _zf.writestr("project.json", json.dumps(
                {k: v for k, v in payload.items() if k != "_project_zip"}
            ))
            _orig = payload.get("_project_zip")
            if _orig:
                try:
                    with zipfile.ZipFile(_io.BytesIO(_orig)) as _ozf:
                        for entry in _ozf.namelist():
                            if entry.startswith("assets/") and not entry.endswith("/"):
                                _zf.writestr(entry, _ozf.read(entry))
                except Exception:
                    pass
        project_zip_path.write_bytes(zip_buf.getvalue())

        render_url = (
            f"{RENDERER_URL}/QweenRender.html"
            f"?src={RENDERER_URL}/projects/{job_id}.zip"
            f"&autoplay=1"  # QweenRender triggers masterTl.play() on load in autoplay mode
        )

        # ── 2. Launch Xvfb ───────────────────────────────────────────────────
        xvfb_cmd = [
            "Xvfb", f":{disp}",
            "-screen", "0", f"{stage_w}x{stage_h}x24",
            "-ac",          # disable access control (allows Chromium to connect)
            "+extension", "GLX",
            "+render",
        ]
        xvfb_proc = subprocess.Popen(xvfb_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)  # give Xvfb time to initialise

        _job_update(job_id, message="Launching browser…", progress=5)

        # ── 3. Launch Chromium non-headless ──────────────────────────────────
        debug_port = 9222 + (disp - _DISPLAY_START)  # unique port per display
        chromium_cmd = [
            "chrome",  # overridden below from CHROMIUM_BIN env
            f"--display=:{disp}",
            "--no-sandbox",
            "--disable-setuid-sandbox",
            "--autoplay-policy=no-user-gesture-required",
            "--disable-web-security",
            f"--remote-debugging-port={debug_port}",
            "--window-size={stage_w},{stage_h}",
            "--start-maximized",
            "--disable-infobars",
            "--disable-extensions",
            "--hide-scrollbars",
            f"--app={render_url}",
        ]
        chromium_bin = os.environ.get("CHROMIUM_BIN") or shutil.which("google-chrome-stable") or shutil.which("google-chrome") or shutil.which("chromium-browser") or shutil.which("chromium")
        if not chromium_bin:
            raise RuntimeError("No Chromium binary found. Set CHROMIUM_BIN in .env")
        chromium_cmd[0] = chromium_bin

        env = {**os.environ, "DISPLAY": f":{disp}"}
        chromium_proc = subprocess.Popen(
            chromium_cmd, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        time.sleep(2.0)  # give Chromium time to open the page

        # ── 4. Poll __qween_ready via CDP ────────────────────────────────────
        # Use chromium's remote debugging port to evaluate JS
        _job_update(job_id, message="Waiting for animation to be ready…", progress=8)
        ready = _cdp_wait_ready(debug_port, timeout=60)
        if not ready:
            raise RuntimeError("Timed out waiting for __qween_ready")

        # ── 5. Start FFmpeg x11grab capture ──────────────────────────────────
        _job_update(job_id, message="Recording…", progress=10)
        raw_capture = job_dir / "capture.mp4"
        ffmpeg_cmd = [
            "ffmpeg", "-y",
            "-f", "x11grab",
            "-r", str(fps),
            "-s", f"{stage_w}x{stage_h}",
            "-i", f":{disp}.0+0,0",
            "-c:v", "libx264",
            "-crf", "0",            # lossless capture — re-encode after
            "-preset", "ultrafast",
            "-pix_fmt", "yuv444p",
            str(raw_capture),
        ]
        ffmpeg_proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)  # let FFmpeg start capturing before triggering playback

        # ── 6. Trigger playback via CDP ───────────────────────────────────────
        _cdp_eval(debug_port, "window.__qween_master_tl && window.__qween_master_tl.play(0)")

        # ── 7. Wait for animation to finish + small buffer ────────────────────
        wait_secs = duration + 1.5  # 1.5s buffer for last frame to paint
        _job_update(job_id, message=f"Recording {duration:.1f}s animation…", progress=12)

        # Poll progress while waiting
        poll_interval = 0.5
        elapsed = 0.0
        while elapsed < wait_secs:
            time.sleep(poll_interval)
            elapsed += poll_interval
            pct = 12 + int((elapsed / wait_secs) * 60)
            _job_update(job_id, progress=min(pct, 72),
                         message=f"Recording… {elapsed:.1f}s / {duration:.1f}s")

        # ── 8. Stop FFmpeg gracefully ─────────────────────────────────────────
        _job_update(job_id, message="Finalising capture…", progress=73)
        if ffmpeg_proc and ffmpeg_proc.poll() is None:
            ffmpeg_proc.terminate()
            try:
                ffmpeg_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                ffmpeg_proc.kill()
        ffmpeg_proc = None

        if not raw_capture.exists() or raw_capture.stat().st_size < 1024:
            raise RuntimeError("FFmpeg capture produced no output — check Xvfb/Chromium setup")

        # ── 9. Re-encode to target format ─────────────────────────────────────
        _job_update(job_id, message="Encoding output…", progress=76)
        output = output_path_for(job_dir, fmt)
        cfg    = FORMAT_CONFIG[fmt]
        encode_args = [
            "-i", str(raw_capture),
            "-c:v", cfg["vcodec"],
            "-pix_fmt", cfg["pix_fmt"],
        ]
        if fmt in ("mp4", "mov"):
            encode_args += ["-crf", str(crf), "-preset", "medium"]
        elif fmt == "webm":
            encode_args += ["-crf", str(crf), "-b:v", "0"]
        encode_args += [str(output)]
        code, _, err = run_ffmpeg(encode_args)
        if code != 0:
            raise RuntimeError(f"FFmpeg encode failed: {err[-500:]}")

        # Clean up lossless intermediate
        raw_capture.unlink(missing_ok=True)

        mb = round(output.stat().st_size / 1_048_576, 2)
        _job_update(job_id, status="done", message=f"Done — {mb} MB",
                     progress=100, size_mb=mb, format=fmt,
                     output=str(output))

    except Exception as exc:
        _job_update(job_id, status="error", message=str(exc), progress=0)

    finally:
        # Kill processes in reverse order, clean up display
        for proc in (ffmpeg_proc, chromium_proc, xvfb_proc):
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        project_zip_path.unlink(missing_ok=True)
        _release_display(disp)


# ── CDP helpers ───────────────────────────────────────────────────────────────
def _cdp_eval(port: int, expression: str) -> Any:
    """Evaluate JS in the first page via Chrome DevTools Protocol REST API."""
    import urllib.request, urllib.error
    try:
        # Get the list of targets
        with urllib.request.urlopen(f"http://localhost:{port}/json", timeout=5) as r:
            targets = json.loads(r.read())
        page_target = next(
            (t for t in targets if t.get("type") == "page"),
            None,
        )
        if not page_target:
            return None
        ws_url = page_target.get("webSocketDebuggerUrl", "")
        # Use the simpler HTTP /json/eval endpoint if available
        eval_url = f"http://localhost:{port}/json/eval/{page_target['id']}"
        # Fall back to websocket eval via playwright-python or websockets
        # For simplicity in this server, we use the CDP HTTP evaluate endpoint
        import urllib.parse
        encoded = urllib.parse.quote(expression)
        req_url = f"http://localhost:{port}/json/runtime/evaluate?expression={encoded}&targetId={page_target['id']}"
        with urllib.request.urlopen(req_url, timeout=5) as r:
            result = json.loads(r.read())
        return result.get("result", {}).get("value")
    except Exception:
        return None


def _cdp_wait_ready(port: int, timeout: int = 60) -> bool:
    """Poll __qween_ready via CDP until true or timeout."""
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://localhost:{port}/json", timeout=3) as r:
                targets = json.loads(r.read())
            if targets:
                # CDP is up — check __qween_ready
                val = _cdp_eval(port, "!!window.__qween_ready")
                if val is True or val == "true":
                    return True
        except Exception:
            pass
        time.sleep(1.0)
    return False


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Health check — verifies Xvfb and FFmpeg are available."""
    checks = {}
    checks["ffmpeg"]   = shutil.which("ffmpeg") is not None
    checks["Xvfb"]     = shutil.which("Xvfb") is not None
    chromium_bin = os.environ.get("CHROMIUM_BIN", "")
    checks["chromium"] = bool(
        (chromium_bin and (shutil.which(chromium_bin) or os.path.isfile(chromium_bin)))
        or shutil.which("google-chrome-stable")
        or shutil.which("google-chrome")
        or shutil.which("chromium-browser")
        or shutil.which("chromium")
    )
    checks["displays_available"] = len(_display_pool) - len(_display_in_use)
    ok = all(v for k, v in checks.items() if k != "displays_available")
    return JSONResponse({"status": "ok" if ok else "degraded", **checks}, status_code=200 if ok else 503)


@app.post("/jobs/render-project")
async def render_project(
    file:         UploadFile = File(...),
    fps:          float = Form(30),
    crf:          int   = Form(18),
    format:       str   = Form("mp4"),
    start_time:   float = Form(0),
    end_time:     float = Form(0),
    stage_width:  int   = Form(1920),
    stage_height: int   = Form(1080),
):
    """Accept a QweenApp project ZIP and render it via Xvfb + FFmpeg x11grab."""
    fmt = format.lower()
    if fmt not in VALID_FORMATS:
        raise HTTPException(400, f"Invalid format '{fmt}'. Choose: {', '.join(sorted(VALID_FORMATS))}")

    raw      = await file.read()
    filename = (file.filename or "upload").lower()

    # ── Parse project ZIP ────────────────────────────────────────────────────
    asset_map: dict[str, str] = {}
    project: dict = {}

    if filename.endswith(".zip") or raw[:2] == b"PK":
        try:
            zf = zipfile.ZipFile(__import__("io").BytesIO(raw))
        except Exception:
            raise HTTPException(400, "Invalid ZIP file.")
        names = zf.namelist()
        if "project.json" not in names:
            raise HTTPException(400, "ZIP must contain project.json.")
        try:
            project = json.loads(zf.read("project.json"))
        except Exception:
            raise HTTPException(400, "project.json is not valid JSON.")

        # Upload embedded video assets to the local store
        for entry in names:
            if not entry.startswith("assets/") or entry.endswith("/"):
                continue
            p = Path(entry)
            if p.suffix.lower() not in ASSET_VIDEO_EXTS:
                continue
            data  = zf.read(entry)
            chash = hashlib.sha256(data).hexdigest()
            with _asset_lock:
                existing = _asset_hash_index.get(chash)
            if existing and (ASSETS_DIR / existing).exists():
                asset_id = existing
            else:
                asset_id  = str(uuid.uuid4())
                asset_dir = ASSETS_DIR / asset_id
                asset_dir.mkdir(parents=True)
                (asset_dir / f"file{p.suffix.lower()}").write_bytes(data)
                with _asset_lock:
                    _asset_hash_index[chash] = asset_id
            asset_map[p.stem] = asset_id
            asset_map[p.name] = asset_id
    else:
        try:
            project = json.loads(raw.decode("utf-8"))
        except Exception:
            raise HTTPException(400, "File is not valid JSON.")

    # ── Build payload ─────────────────────────────────────────────────────────
    nodes_raw   = project.get("nodes", [])
    stage_w     = stage_width  or next((n.get("width", 1920) for n in nodes_raw if n.get("width")), 1920)
    stage_h     = stage_height or next((n.get("height", 1080) for n in nodes_raw if n.get("height")), 1080)
    tweens      = project.get("tweens", [])
    _end_time   = end_time or _estimate_timeline_end(tweens)
    _start_time = start_time

    if _end_time <= _start_time:
        raise HTTPException(400, "Could not determine endTime. Pass end_time explicitly.")

    payload = {
        "fps":         fps,
        "crf":         crf,
        "format":      fmt,
        "startTime":   _start_time,
        "endTime":     _end_time,
        "stageWidth":  stage_w,
        "stageHeight": stage_h,
        "nodes":       nodes_raw,
        "tweens":      tweens,
        "timelineLoop":    project.get("timelineLoop", False),
        "timelineYoyo":    project.get("timelineYoyo", False),
        "timelineReverse": project.get("timelineReverse", False),
        "timelineSpeed":   project.get("timelineSpeed", 1),
        "globalDataSources": project.get("globalDataSources", []),
        "swapTemplates":     project.get("swapTemplates", []),
        "storedInitialStates": project.get("initialStates", []),
        "gsapCdn": "https://cdnjs.cloudflare.com/ajax/libs/gsap/3.13.0/gsap.min.js",
        "_project_zip": raw,
    }

    # ── Queue job ─────────────────────────────────────────────────────────────
    job_id, job_dir = new_job(label=f"xvfb-render → {fmt.upper()}")
    threading.Thread(
        target=_run_xvfb_render,
        args=(job_id, job_dir, payload, fmt, fps, crf),
        daemon=True,
    ).start()

    return {
        "job_id":   job_id,
        "status":   "queued",
        "poll_url": f"/jobs/{job_id}/status",
        "end_time": _end_time,
        "stage":    f"{stage_w}×{stage_h}",
        "format":   fmt,
        "fps":      fps,
        "renderer": "xvfb",
    }


@app.get("/jobs/{job_id}/status")
async def job_status(job_id: str):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Job not found.")
    return job


@app.get("/jobs/{job_id}/download")
async def job_download(job_id: str):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Job not found.")
    if job["status"] != "done":
        raise HTTPException(400, f"Job not done (status: {job['status']}).")
    output = Path(job["output"])
    if not output.exists():
        raise HTTPException(404, "Output file missing.")
    fmt  = job.get("format", "mp4")
    mime = FORMAT_CONFIG.get(fmt, {}).get("mime", "video/mp4")
    return FileResponse(output, media_type=mime, filename=f"render_{job_id[:8]}{FORMAT_CONFIG[fmt]['ext']}")


# ── Auto-cleanup ──────────────────────────────────────────────────────────────
def _sweep_old_jobs():
    while True:
        time.sleep(3600)
        cutoff = time.time() - AUTO_CLEAN_HOURS * 3600
        with _jobs_lock:
            stale = [jid for jid, j in _jobs.items() if j.get("created_at", 0) < cutoff]
        for jid in stale:
            job_dir = WORK_DIR / jid
            shutil.rmtree(job_dir, ignore_errors=True)
            with _jobs_lock:
                _jobs.pop(jid, None)


threading.Thread(target=_sweep_old_jobs, daemon=True).start()
