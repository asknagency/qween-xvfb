#!/bin/bash
# ── qween-xvfb test script ────────────────────────────────────────────────────
# Tests the full render pipeline: health → submit → poll → download
# Uses snskl.zip (the real QweenApp project) as the test asset.
#
# Usage: bash test.sh [base_url] [format]
#   base_url defaults to http://localhost:8000
#   format   defaults to mp4 (also: mov, webm)
#
# CodeSandbox: the API port is auto-proxied, so you can pass the CSB URL:
#   bash test.sh https://hhx62k-8000.csb.app

BASE="${1:-http://localhost:8000}"
FORMAT="${2:-mp4}"
OUTPUT="test_render.$FORMAT"
POLL_INTERVAL=3
TIMEOUT=180

# ── The real project zip to use as the test payload ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ZIP="$SCRIPT_DIR/snskl.zip"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${CYAN}→${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  qween-xvfb render test"
echo "  $BASE  |  format: $FORMAT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[ -f "$PROJECT_ZIP" ] || fail "Test zip not found: $PROJECT_ZIP"

# ── 1. Health check ───────────────────────────────────────────────────────────
info "Checking health..."
HEALTH=$(curl -sf "$BASE/health") || fail "API not reachable at $BASE — is it running?"

STATUS=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))")
FFMPEG=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ffmpeg','?'))")
XVFB=$(echo "$HEALTH"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Xvfb','?'))")
CHROME=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('chromium','?'))")

echo "   ffmpeg:   $FFMPEG"
echo "   Xvfb:     $XVFB"
echo "   chromium: $CHROME"
echo "   status:   $STATUS"
echo ""

[ "$STATUS" = "ok" ] || fail "Health status is '$STATUS' — check that Xvfb, Chrome and FFmpeg are installed."
[ "$FFMPEG" = "True" ]  || fail "FFmpeg not found"
[ "$XVFB" = "True" ]    || fail "Xvfb not found"
[ "$CHROME" = "True" ]  || fail "Chromium not found — check CHROMIUM_BIN in .env"
ok "Health OK"
echo ""

# ── 2. Detect RENDERER_URL ────────────────────────────────────────────────────
# In CodeSandbox every port gets a unique subdomain proxy URL.
# Chrome's CDP is on port 9222 (first display); its CSB URL follows the same
# pattern as the API URL — just swap the port number.
#
# If BASE looks like a CSB proxy (*.csb.app), derive the renderer + CDP URLs
# from it automatically. Otherwise fall back to localhost.
if echo "$BASE" | grep -q '\.csb\.app'; then
  # Extract the sandbox ID prefix, e.g. "hhx62k" from https://hhx62k-8000.csb.app
  CSB_PREFIX=$(echo "$BASE" | sed 's|https\?://\([a-z0-9]*\)-[0-9]*\.csb\.app.*|\1|')
  RENDERER_URL="https://${CSB_PREFIX}-3001.csb.app"
  CDP_URL="https://${CSB_PREFIX}-9222.csb.app"
  warn "CodeSandbox detected — using proxied URLs"
  echo "   renderer: $RENDERER_URL"
  echo "   CDP:      $CDP_URL"
else
  RENDERER_URL="${RENDERER_URL:-http://localhost:3001}"
  CDP_URL="http://localhost:9222"
fi
echo ""

# ── 3. Submit render job ──────────────────────────────────────────────────────
info "Submitting render job (snskl.zip — 1080×1080, 2s)..."
RESPONSE=$(curl -sf -X POST "$BASE/jobs/render-project" \
  -F "file=@$PROJECT_ZIP" \
  -F "fps=30" \
  -F "format=$FORMAT" \
  -F "stage_width=1080" \
  -F "stage_height=1080" \
  -F "end_time=2") || fail "Failed to submit job — is the API running?"

echo "$RESPONSE" | python3 -m json.tool
echo ""

JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
[ -n "$JOB_ID" ] || fail "No job_id in response"
ok "Job queued: $JOB_ID"
echo ""

# ── 4. Poll until done ────────────────────────────────────────────────────────
info "Polling status (timeout: ${TIMEOUT}s)..."
ELAPSED=0
while true; do
  POLL=$(curl -sf "$BASE/jobs/$JOB_ID/status") || fail "Status endpoint failed"
  JOB_STATUS=$(echo "$POLL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
  MSG=$(echo "$POLL"        | python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
  PROGRESS=$(echo "$POLL"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('progress',0))" 2>/dev/null)

  printf "\r   [%3ds] %3s%%  %-14s %s" "$ELAPSED" "$PROGRESS" "$JOB_STATUS" "$MSG"

  if [ "$JOB_STATUS" = "done" ]; then
    echo ""
    ok "Render complete!"
    break
  fi

  if [ "$JOB_STATUS" = "error" ]; then
    echo ""
    echo ""
    echo "$POLL" | python3 -m json.tool
    fail "Render failed — see error above"
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo ""
    fail "Timed out after ${TIMEOUT}s (status: $JOB_STATUS)"
  fi
done
echo ""

# ── 5. Download output ────────────────────────────────────────────────────────
info "Downloading $OUTPUT..."
curl -sf -o "$OUTPUT" "$BASE/jobs/$JOB_ID/download" || fail "Download failed"
SIZE=$(du -h "$OUTPUT" | cut -f1)
ok "Saved: $OUTPUT ($SIZE)"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}All tests passed!${NC}"
echo "  Output: $(pwd)/$OUTPUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
