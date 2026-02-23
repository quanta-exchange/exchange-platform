#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/anomaly}"
PORT="${ANOMALY_SMOKE_PORT:-auto}"

if [[ "$PORT" == "auto" ]]; then
  PORT="$(
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
  )"
fi

TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/smoke-$TS_ID"
WEBHOOK_CAPTURE="$RUN_DIR/webhook-capture.json"
REPORT_FILE="$RUN_DIR/anomaly-smoke.json"
LATEST_FILE="$OUT_DIR/anomaly-smoke-latest.json"

mkdir -p "$RUN_DIR"

python3 - "$PORT" "$WEBHOOK_CAPTURE" >"$RUN_DIR/webhook-server.log" 2>&1 <<'PY' &
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
capture_path = pathlib.Path(sys.argv[2]).resolve()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        capture_path.parent.mkdir(parents=True, exist_ok=True)
        capture_path.write_bytes(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, _fmt, *_args):
        return


server = HTTPServer(("127.0.0.1", port), Handler)
server.handle_request()
server.server_close()
PY
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

sleep 0.2
if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  echo "webhook test server failed to start on port ${PORT}" >&2
  cat "$RUN_DIR/webhook-server.log" >&2 || true
  exit 1
fi

OUT_DIR="$RUN_DIR" "$ROOT_DIR/scripts/anomaly_detector.sh" \
  --force-anomaly \
  --allow-anomaly \
  --webhook-url "http://127.0.0.1:${PORT}/hook" \
  --require-webhook-delivery \
  >"$RUN_DIR/anomaly-detector.log"

wait "$SERVER_PID"
trap - EXIT

python3 - "$REPORT_FILE" "$WEBHOOK_CAPTURE" "$RUN_DIR/anomaly-detector.log" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
webhook_capture = pathlib.Path(sys.argv[2]).resolve()
detector_log = pathlib.Path(sys.argv[3]).resolve()

webhook_payload = None
webhook_ok = False
if webhook_capture.exists():
    try:
        webhook_payload = json.loads(webhook_capture.read_text(encoding="utf-8"))
        webhook_ok = bool(webhook_payload.get("anomaly_detected"))
    except Exception:
        webhook_ok = False

detector_report = None
for raw in detector_log.read_text(encoding="utf-8", errors="ignore").splitlines():
    if raw.startswith("anomaly_report="):
        detector_report = raw.split("=", 1)[1].strip()
        break

ok = webhook_ok and detector_report is not None
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "detector_report": detector_report,
    "webhook_capture_file": str(webhook_capture),
    "webhook_received": webhook_capture.exists(),
    "webhook_payload_anomaly_detected": webhook_ok,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

SMOKE_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "anomaly_smoke_report=$REPORT_FILE"
echo "anomaly_smoke_latest=$LATEST_FILE"
echo "anomaly_smoke_ok=$SMOKE_OK"

if [[ "$SMOKE_OK" != "true" ]]; then
  exit 1
fi
