#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

pass() { echo "[PASS] $1"; }
warn() { echo "[WARN] $1"; }
fail() { echo "[FAIL] $1"; failures=$((failures+1)); }

require_cmd() {
  local cmd="$1"; shift
  local hint="$*"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd: $("$cmd" --version 2>/dev/null | head -n 1 || true)"
  else
    fail "$cmd not found. ${hint}"
  fi
}

echo "== Exchange Platform Doctor =="

echo "-- Container runtime --"
if command -v docker >/dev/null 2>&1; then
  pass "docker: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    pass "docker compose: $(docker compose version | head -n 1)"
  else
    fail "docker compose not available. Install Docker Desktop >= 4.x (includes compose v2)."
  fi
else
  fail "docker not found. Install Docker Desktop for macOS: https://docs.docker.com/desktop/setup/install/mac-install/."
fi

echo "-- Protobuf toolchain --"
if command -v protoc >/dev/null 2>&1; then
  pass "protoc: $(protoc --version)"
  if [[ -f /opt/homebrew/include/google/protobuf/timestamp.proto || -f /usr/local/include/google/protobuf/timestamp.proto ]]; then
    pass "protoc well-known types include path detected"
  else
    warn "google/protobuf/timestamp.proto not found in /opt/homebrew/include or /usr/local/include"
    warn "If cargo test fails with timestamp.proto missing: brew install protobuf"
  fi
else
  fail "protoc not found. Install with: brew install protobuf"
fi

echo "-- Rust --"
if command -v rustc >/dev/null 2>&1; then
  pass "rustc: $(rustc --version)"
else
  fail "rustc not found. Install with: curl https://sh.rustup.rs -sSf | sh"
fi
if command -v cargo >/dev/null 2>&1; then
  pass "cargo: $(cargo --version)"
else
  fail "cargo not found. Install via rustup (same as rustc)."
fi

echo "-- Go --"
if command -v go >/dev/null 2>&1; then
  pass "go: $(go version)"
else
  fail "go not found. Install with: brew install go"
fi

echo "-- Java / Gradle --"
if command -v java >/dev/null 2>&1; then
  java_line="$(java -version 2>&1 | head -n 1)"
  pass "java: ${java_line}"
  if echo "$java_line" | grep -Eq '"(17|21)(\.|")'; then
    pass "java major version is supported (17/21)"
  else
    fail "java must be 17 or 21. Install and select one: brew install openjdk@21 && export JAVA_HOME=\$(/usr/libexec/java_home -v 21)"
  fi
else
  fail "java not found. Install with: brew install openjdk@21"
fi

if [[ -x "$ROOT_DIR/gradlew" ]]; then
  pass "gradlew present"
  if "$ROOT_DIR/gradlew" -v >/tmp/gradle-version-doctor.log 2>&1; then
    pass "gradlew runnable: $(grep -m1 "^Gradle " /tmp/gradle-version-doctor.log || echo "gradle version output captured")"
  else
    fail "./gradlew failed to run. Check JAVA_HOME and local JDK install. See /tmp/gradle-version-doctor.log"
  fi
else
  fail "./gradlew missing or not executable"
fi

if [[ "$failures" -gt 0 ]]; then
  echo
  echo "Doctor failed with ${failures} issue(s). Fix the FAIL items above, then rerun: make doctor"
  exit 1
fi

echo
pass "Environment looks ready for smoke_match.sh"
