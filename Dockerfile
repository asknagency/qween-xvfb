FROM python:3.12-slim

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Virtual display
    xvfb \
    # Chromium
    chromium \
    chromium-driver \
    # FFmpeg with x11grab support (must be built with --enable-x11grab)
    ffmpeg \
    # X11 utilities
    x11-utils \
    xdotool \
    # Fonts (for SVG text rendering in Chromium)
    fonts-liberation \
    fonts-dejavu-core \
    # Shared libraries Chromium needs in a slim container
    libglib2.0-0 \
    libnss3 \
    libnspr4 \
    libdbus-1-3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libcairo2 \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies ────────────────────────────────────────────────────────
WORKDIR /app
COPY apps/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Application ───────────────────────────────────────────────────────────────
COPY apps/ ./apps/

# Static files server for QweenRender.html (served by apps/app/server.js or nginx)
# The render server itself only needs the projects/ directory to write ZIPs into.
RUN mkdir -p apps/app/public/projects apps/api/assets

# ── Environment ───────────────────────────────────────────────────────────────
ENV PYTHONUNBUFFERED=1
ENV CHROMIUM_BIN=chromium
ENV RENDERER_URL=http://localhost:3001
ENV MAX_CONCURRENT_RENDERS=2

# Expose API port
EXPOSE 8000

# ── Startup ───────────────────────────────────────────────────────────────────
# Start the static file server (Node) and the FastAPI render server together.
# In production, use a proper process manager (supervisord / PM2).
CMD ["uvicorn", "apps.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
