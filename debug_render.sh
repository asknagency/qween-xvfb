#!/bin/bash
# ── debug_render.sh ───────────────────────────────────────────────────────────
# Runs each step of the render pipeline manually so you can see exactly
# where it breaks. Run this in the CodeSandbox terminal.
# Usage: bash debug_render.sh

LOG="$(dirname "$0")/debug_output.log"
exec > >(tee "$LOG") 2>&1
echo "Full log: $LOG"
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
svg = (
  '<svg id="main-svg-root" xmlns="http://www.w3.org/2000/svg" ' 
  'viewBox="0 0 1920 1080" width="1920" height="1080">' 
  '<rect id="box1" x="100" y="440" width="200" height="200" rx="16" fill="#e53935"/>' 
  '</svg>'
)
proj = {
  "nodes": [{"id": "node-1", "type": "svg", "width": 1920, "height": 1080, "_svgContent": svg}],
  "tweens": [{
    "id": "t1",
    "selectedElementIds": ["box1"],
    "type": "to",
    "toVars": {"x": 1700},
    "timingVars": {"duration": 2, "ease": "power2.inOut"},
    "position": 0
  }]
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
  --disable-features=IsolateOrigins,site-per-process \
  --remote-debugging-port=$PORT \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir=/tmp/chrome-debug-profile \
  --window-size=${STAGE_W},${STAGE_H} \
  --disable-infobars \
  --disable-extensions \
  --hide-scrollbars \
  --disable-gpu \
  --disable-dev-shm-usage \
  "$RENDER_URL" \
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

# ── Step 8: Capture console errors + check __qween_ready ─────────────────────
info "Step 8: Capture JS console errors and check __qween_ready (one shot)"
python3 - <<PYEOF
import asyncio, json, urllib.request, sys
try:
    import websockets
except ImportError:
    print("websockets not installed")
    sys.exit(1)

PORT = $PORT

async def check():
    with urllib.request.urlopen(f"http://localhost:{PORT}/json", timeout=5) as r:
        targets = json.loads(r.read())
    page = next((t for t in targets if t.get("type") == "page"), None)
    if not page:
        print(f"No page target: {targets}")
        return
    ws_url = page.get("webSocketDebuggerUrl")
    print(f"Connecting to: {ws_url}")

    async with websockets.connect(ws_url, open_timeout=10, additional_headers={"Host": "localhost"}) as ws:
        # Enable console log capture and runtime exceptions
        for method in ["Runtime.enable", "Log.enable", "Console.enable"]:
            await ws.send(json.dumps({"id": 0, "method": method, "params": {}}))

        # Wait 8 seconds collecting all events, then check state
        console_msgs = []
        exceptions = []
        deadline = asyncio.get_event_loop().time() + 8
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=1)
                msg = json.loads(raw)
                method = msg.get("method", "")
                if method == "Runtime.consoleAPICalled":
                    args = msg.get("params", {}).get("args", [])
                    text = " ".join(str(a.get("value", a.get("description", ""))) for a in args)
                    t = msg["params"].get("type", "log")
                    console_msgs.append(f"[{t}] {text}")
                elif method == "Runtime.exceptionThrown":
                    exc = msg["params"]["exceptionDetails"]
                    exceptions.append(f"EXCEPTION: {exc.get('text','')} {exc.get('exception',{}).get('description','')}")
                elif method == "Log.entryAdded":
                    entry = msg["params"]["entry"]
                    console_msgs.append(f"[{entry.get('level','?')}] {entry.get('text','')}")
            except asyncio.TimeoutError:
                pass

        # Now check the actual JS state
        await ws.send(json.dumps({"id": 99, "method": "Runtime.evaluate", "params": {
            "expression": "JSON.stringify({ready: !!window.__qween_ready, error: window.__qween_error || null})",
            "returnByValue": True
        }}))
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
            resp = json.loads(raw)
            if resp.get("id") == 99:
                val = resp.get("result", {}).get("result", {}).get("value", "{}")
                print(f"\n=== JS State ===")
                print(val)
                break

        print(f"\n=== Console ({len(console_msgs)} messages) ===")
        for m in console_msgs[-30:]:
            print(m)

        print(f"\n=== Exceptions ({len(exceptions)}) ===")
        for e in exceptions:
            print(e)

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
