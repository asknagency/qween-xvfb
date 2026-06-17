# ── Base: Playwright's official Python image (Ubuntu Jammy) ──────────────────
# Pre-installs Chromium + all its system deps. No PPA, no apt failures.
FROM mcr.microsoft.com/playwright/python:v1.44.0-jammy

# ── System extras: FFmpeg + display tools ────────────────────────────────────
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      ffmpeg \
      x11-utils \
      xdotool \
      curl \
    && rm -rf /var/lib/apt/lists/*

# ── Node 20 + pnpm ───────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@9.1.0 \
    && rm -rf /var/lib/apt/lists/*

# ── Python deps pre-baked ────────────────────────────────────────────────────
COPY apps/api/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ── Env ───────────────────────────────────────────────────────────────────────
# The playwright image puts chromium at a versioned path; use python -m playwright
# to find it reliably at runtime, or set CHROMIUM_BIN in .env after first boot.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV RENDERER_URL=http://localhost:3001
ENV MAX_CONCURRENT_RENDERS=2
