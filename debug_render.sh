#!/bin/bash
# ── debug_render.sh ───────────────────────────────────────────────────────────
# Runs each step of the render pipeline manually so you can see exactly
# where it breaks. Run this in the CodeSandbox terminal.
# Usage: bash debug_render.sh

set -e
DISP=99
PORT=9222
STAGE_W=1920
STAGE_H=1080
RENDERER=http://localhost:3001
CHROME=$(which google-chrome-stable || which google-chrome || echo "")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗ FAILED: $1${NC}"; }
info() { echo -e "${CYAN}→${NC} $1"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  qween render pipeline debug"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Check binaries ────────────────────────────────────────────────────
info "Step 1: Check binaries"
which Xvfb   && ok "Xvfb:    $(which Xvfb)"   || fail "Xvfb not found"
which ffmpeg && ok "ffmpeg:  $(which ffmpeg)" || fail "ffmpeg not found"
[ -n "$CHROME" ] && ok "chrome:  $CHROME"     || fail "No chrome binary found"
echo ""

# ── Step 2: Check renderer is up ─────────────────────────────────────────────
info "Step 2: Check Node renderer at $RENDERER"
curl -sf "$RENDERER/health" | python3 -m json.tool && ok "Renderer is up" || fail "Renderer not responding — is the Node task running?"
echo ""

# ── Step 3: Write a test ZIP ──────────────────────────────────────────────────
info "Step 3: Write test project ZIP to renderer projects dir"
PROJECT_DIR="$(dirname "$0")/apps/app/public/projects"
mkdir -p "$PROJECT_DIR"
TEST_ID="debug-test-$(date +%s)"
python3 - <<PYEOF
import zipfile, json, sys
proj = {
  "nodes": [{"id":"box1","type":"shape","x":100,"y":400,"width":200,"height":200,"fill":"#e53935"}],
  "tweens": [{"id":"t1","nodeId":"box1","prop":"x","from":100,"to":1700,"start":0,"duration":2,"ease":"power2.inOut"}]
}
path = "$PROJECT_DIR/$TEST_ID.zip"
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr("project.json", json.dumps(proj))
print(f"Written: {path}")
PYEOF
ok "ZIP written"

# ── Step 4: Check ZIP is fetchable from renderer ──────────────────────────────
info "Step 4: Verify renderer serves the ZIP"
STATUS=$(curl -so /dev/null -w "%{http_code}" "$RENDERER/projects/$TEST_ID.zip")
echo "   HTTP status: $STATUS"
[ "$STATUS" = "200" ] && ok "ZIP is fetchable" || fail "Renderer returned $STATUS for /projects/$TEST_ID.zip"
echo ""

# ── Step 5: Launch Xvfb ───────────────────────────────────────────────────────
info "Step 5: Launch Xvfb :$DISP"
pkill -f "Xvfb :$DISP" 2>/dev/null || true
Xvfb :$DISP -screen 0 ${STAGE_W}x${STAGE_H}x24 -ac +extension GLX +render &
XVFB_PID=$!
sleep 1
kill -0 $XVFB_PID 2>/dev/null && ok "Xvfb running (pid $XVFB_PID)" || fail "Xvfb failed to start"
echo ""

# ── Step 6: Launch Chrome ─────────────────────────────────────────────────────
RENDER_URL="$RENDERER/QweenRender.html?src=$RENDERER/projects/$TEST_ID.zip&autoplay=1"
info "Step 6: Launch Chrome"
echo "   URL: $RENDER_URL"
pkill -f "remote-debugging-port=$PORT" 2>/dev/null || true
sleep 0.5
DISPLAY=:$DISP "$CHROME" \
  --no-sandbox \
  --disable-setuid-sandbox \
  --autoplay-policy=no-user-gesture-required \
  --disable-web-security \
  --remote-debugging-port=$PORT \
  --window-size=${STAGE_W},${STAGE_H} \
  --disable-infobars \
  --disable-extensions \
  --hide-scrollbars \
  --app="$RENDER_URL" \
  > /tmp/chrome_debug.log 2>&1 &
CHROME_PID=$!
sleep 3
kill -0 $CHROME_PID 2>/dev/null && ok "Chrome running (pid $CHROME_PID)" || { fail "Chrome crashed"; cat /tmp/chrome_debug.log; echo ""; }
echo ""

# ── Step 7: Check CDP ─────────────────────────────────────────────────────────
info "Step 7: Check CDP on port $PORT"
for i in $(seq 1 10); do
  RESULT=$(curl -sf "http://localhost:$PORT/json" 2>/dev/null)
  if [ -n "$RESULT" ]; then
    ok "CDP is up"
    echo "$RESULT" | python3 -m json.tool
    break
  fi
  echo "   waiting... ($i/10)"
  sleep 1
done
[ -z "$RESULT" ] && fail "CDP never came up on port $PORT"
echo ""

# ── Step 8: Check __qween_ready via CDP WebSocket ────────────────────────────
info "Step 8: Poll __qween_ready for up to 30s"
python3 - <<PYEOF
import asyncio, json, urllib.request, time, sys
try:
    import websockets
except ImportError:
    print("websockets not installed — run: pip install websockets")
    sys.exit(1)

PORT = $PORT
deadline = time.time() + 30

async def check():
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://localhost:{PORT}/json", timeout=3) as r:
                targets = json.loads(r.read())
            page = next((t for t in targets if t.get("type") == "page"), None)
            if not page:
                print(f"  no page target yet, targets={[t.get('type') for t in targets]}")
                await asyncio.sleep(1)
                continue
            ws_url = page.get("webSocketDebuggerUrl")
            print(f"  page URL: {page.get('url','?')[:80]}")
            async with websockets.connect(ws_url, open_timeout=5) as ws:
                await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":"JSON.stringify({ready: !!window.__qween_ready, error: window.__qween_error, url: location.href})","returnByValue":True}}))
                while True:
                    raw = await asyncio.wait_for(ws.recv(), timeout=8)
                    resp = json.loads(raw)
                    if resp.get("id") == 1:
                        val = resp.get("result",{}).get("result",{}).get("value")
                        print(f"  JS state: {val}")
                        parsed = json.loads(val) if val else {}
                        if parsed.get("ready"):
                            print("✓ __qween_ready is TRUE")
                            return True
                        break
        except Exception as e:
            print(f"  exception: {e}")
        await asyncio.sleep(2)
    print("✗ Timed out — __qween_ready never became true")
    return False

asyncio.run(check())
PYEOF
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
info "Cleaning up..."
kill $CHROME_PID 2>/dev/null || true
kill $XVFB_PID  2>/dev/null || true
rm -f "$PROJECT_DIR/$TEST_ID.zip"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Debug complete. Share the output above."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
