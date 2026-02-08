#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/safety-case"
RUN_CHECKS=false
UPLOAD_MINIO=false
MINIO_ALIAS="local"
MINIO_URL="http://localhost:19002"
MINIO_ACCESS_KEY="minio"
MINIO_SECRET_KEY="minio123"
MINIO_BUCKET="exchange-archive"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --run-checks)
      RUN_CHECKS=true
      shift
      ;;
    --upload-minio)
      UPLOAD_MINIO=true
      shift
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR/reports"

relpath() {
  python3 - "$1" "$2" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
    return
  fi
  shasum -a 256 "$file"
}

run_cmd() {
  local name="$1"
  shift
  echo "running=$name"
  if "$@" >"$OUT_DIR/reports/$name.log" 2>&1; then
    echo "result=$name:pass"
    return 0
  fi
  echo "result=$name:fail"
  return 1
}

if [[ "$RUN_CHECKS" == "true" ]]; then
  run_cmd "buf-lint" buf lint
  run_cmd "buf-generate" buf generate
  run_cmd "cargo-test" cargo test -p trading-core
  run_cmd "go-test" go test ./...
  run_cmd "gradle-test" ./gradlew test
  run_cmd "load-smoke" ./scripts/load_smoke.sh
  run_cmd "dr-rehearsal" ./scripts/dr_rehearsal.sh
fi

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

LOAD_REPORT="$ROOT_DIR/build/load/load-smoke.json"
DR_REPORT="$ROOT_DIR/build/dr/dr-report.json"

if [[ ! -f "$LOAD_REPORT" ]]; then
  echo "missing load report: $LOAD_REPORT"
  exit 1
fi
if [[ ! -f "$DR_REPORT" ]]; then
  echo "missing dr report: $DR_REPORT"
  exit 1
fi

MANIFEST="$OUT_DIR/manifest.json"
cat > "$MANIFEST" <<JSON
{
  "generated_at_utc": "$TS",
  "git_commit": "$COMMIT",
  "git_branch": "$BRANCH",
  "build_metadata": {
    "go_version": "$(go version | sed 's/"/\\"/g')",
    "rust_version": "$(rustc --version | sed 's/"/\\"/g')",
    "java_version": "$(java -version 2>&1 | head -n 1 | sed 's/"/\\"/g')"
  },
  "evidence": [
    "build/load/load-smoke.json",
    "build/dr/dr-report.json"
  ]
}
JSON

ARTIFACT_BASENAME="safety-case-${COMMIT:0:12}"
TARBALL="$OUT_DIR/${ARTIFACT_BASENAME}.tar.gz"
MANIFEST_REL="$(relpath "$ROOT_DIR" "$MANIFEST")"
REPORTS_REL="$(relpath "$ROOT_DIR" "$OUT_DIR/reports")"
(
  cd "$ROOT_DIR"
  tar -czf "$TARBALL" \
    build/load/load-smoke.json \
    build/dr/dr-report.json \
    "$MANIFEST_REL" \
    "$REPORTS_REL"
)

SHA_FILE="$TARBALL.sha256"
sha256_file "$TARBALL" > "$SHA_FILE"

if [[ "$UPLOAD_MINIO" == "true" ]]; then
  docker run --rm --network host minio/mc:RELEASE.2025-01-17T23-25-50Z \
    sh -c "mc alias set $MINIO_ALIAS $MINIO_URL $MINIO_ACCESS_KEY $MINIO_SECRET_KEY && \
           mc mb -p $MINIO_ALIAS/$MINIO_BUCKET >/dev/null 2>&1 || true && \
           mc cp '$TARBALL' '$MINIO_ALIAS/$MINIO_BUCKET/' && \
           mc cp '$SHA_FILE' '$MINIO_ALIAS/$MINIO_BUCKET/'"
fi

echo "safety_case_manifest=$MANIFEST"
echo "safety_case_artifact=$TARBALL"
echo "safety_case_sha256=$SHA_FILE"
