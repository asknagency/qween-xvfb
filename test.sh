#!/bin/bash
# ── qween-xvfb test script ────────────────────────────────────────────────────
# Tests the full render pipeline: health → submit → poll → download
# Usage: bash test.sh [base_url] [format]
#   base_url defaults to http://localhost:8000
#   format defaults to mp4 (also: mov, webm)

BASE="${1:-http://localhost:8000}"
FORMAT="${2:-mp4}"
OUTPUT="test_render.$FORMAT"
POLL_INTERVAL=3
TIMEOUT=120

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

# ── 2. Create a minimal project.json ─────────────────────────────────────────
info "Building test project (red box sliding across screen, 2s)..."
PROJECT_JSON=$(cat <<'JSON'
{
  "nodes": [
    {
      "id": "node-1",
      "type": "svg",
      "width": 1920,
      "height": 1080,
      "_svgContent": "<svg id=\"main-svg-root\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1920 1080\" width=\"1920\" height=\"1080\"><rect id=\"box1\" x=\"100\" y=\"440\" width=\"200\" height=\"200\" rx=\"16\" fill=\"#e53935\"/></svg>"
    }
  ],
  "tweens": [
    {
      "id": "t1",
      "selectedElementIds": ["box1"],
      "type": "to",
      "toVars": {"x": 1700},
      "timingVars": {"duration": 2, "ease": "power2.inOut"},
      "position": 0
    }
  ]
}
JSON
)

TMPFILE=$(mktemp /tmp/qween_test_XXXX.json)
echo "$PROJECT_JSON" > "$TMPFILE"
ok "Project JSON written to $TMPFILE"
echo ""

# ── 3. Submit render job ──────────────────────────────────────────────────────
info "Submitting render job..."
RESPONSE=$(curl -sf -X POST "$BASE/jobs/render-project" \
  -F "file=@$TMPFILE;type=application/json" \
  -F "fps=30" \
  -F "format=$FORMAT" \
  -F "end_time=2" \
  -F "stage_width=1920" \
  -F "stage_height=1080") || fail "Failed to submit job — is the API running?"

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

  printf "\r   [%3ds] status: %-12s %s" "$ELAPSED" "$JOB_STATUS" "$MSG"

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

rm -f "$TMPFILE"
