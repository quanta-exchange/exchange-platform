#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_FILE="${SPEC_FILE:-$ROOT_DIR/specs/state_machines.json}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/model-check}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "missing spec file: $SPEC_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/model-check-$TS_ID.json"
LATEST_FILE="$OUT_DIR/model-check-latest.json"

"$PYTHON_BIN" - "$SPEC_FILE" "$REPORT_FILE" <<'PY'
import json
import sys
from collections import deque
from datetime import datetime, timezone

spec_path = sys.argv[1]
report_path = sys.argv[2]

with open(spec_path, "r", encoding="utf-8") as f:
    spec = json.load(f)

machines = spec.get("machines", {})
errors = []
warnings = []
machine_reports = {}


def validate_path(machine_name: str, machine: dict, path: list[str]) -> tuple[bool, str]:
    states = set(machine.get("states", []))
    transitions = machine.get("transitions", {})
    initial = machine.get("initial")

    if not path:
        return False, "path is empty"
    if path[0] != initial:
        return False, f"path starts at {path[0]} not initial {initial}"

    for i, state in enumerate(path):
        if state not in states:
            return False, f"unknown state '{state}' at index {i}"
        if i == len(path) - 1:
            break
        nxt = path[i + 1]
        allowed = transitions.get(state, [])
        if nxt not in allowed:
            return False, f"invalid transition {state}->{nxt}"

    return True, "ok"


for name, machine in machines.items():
    states = list(machine.get("states", []))
    states_set = set(states)
    transitions = machine.get("transitions", {})
    terminal = set(machine.get("terminal", []))
    rank = machine.get("rank", {})
    initial = machine.get("initial")

    local_errors = []
    local_warnings = []

    if not states:
        local_errors.append("states list is empty")
    if initial not in states_set:
        local_errors.append(f"initial state '{initial}' is not in states")
    if not terminal:
        local_errors.append("terminal states list is empty")
    if not terminal.issubset(states_set):
        local_errors.append("terminal states must be subset of states")
    if set(rank.keys()) != states_set:
        local_errors.append("rank must cover every state exactly once")

    for src, dsts in transitions.items():
        if src not in states_set:
            local_errors.append(f"transition source '{src}' is unknown")
            continue
        for dst in dsts:
            if dst not in states_set:
                local_errors.append(f"transition target '{dst}' from '{src}' is unknown")
                continue
            if rank and rank[dst] < rank[src]:
                local_errors.append(f"non-monotonic transition {src}->{dst}")

    for t_state in terminal:
        dsts = transitions.get(t_state, [])
        if dsts:
            local_errors.append(f"terminal state '{t_state}' has outgoing transitions")

    # Reachability scan.
    reachable = set()
    if initial in states_set:
        queue = deque([initial])
        while queue:
            cur = queue.popleft()
            if cur in reachable:
                continue
            reachable.add(cur)
            for nxt in transitions.get(cur, []):
                if nxt not in reachable:
                    queue.append(nxt)

    unreachable = sorted(states_set - reachable)
    if unreachable:
        local_warnings.append(f"unreachable states: {', '.join(unreachable)}")

    valid_paths = machine.get("valid_paths", [])
    valid_path_results = []
    for idx, path in enumerate(valid_paths, start=1):
        ok, reason = validate_path(name, machine, path)
        valid_path_results.append(
            {"index": idx, "path": path, "ok": ok, "reason": reason}
        )
        if not ok:
            local_errors.append(f"valid_paths[{idx}] failed: {reason}")

    invalid_paths = machine.get("invalid_paths", [])
    invalid_path_results = []
    for idx, path in enumerate(invalid_paths, start=1):
        ok, reason = validate_path(name, machine, path)
        invalid_path_results.append(
            {"index": idx, "path": path, "rejected": not ok, "reason": reason}
        )
        if ok:
            local_errors.append(f"invalid_paths[{idx}] unexpectedly accepted")

    if reachable and terminal and not (reachable & terminal):
        local_errors.append("no terminal state is reachable from initial")

    machine_reports[name] = {
        "state_count": len(states),
        "transition_count": sum(len(v) for v in transitions.values()),
        "reachable_states": sorted(reachable),
        "unreachable_states": unreachable,
        "valid_path_results": valid_path_results,
        "invalid_path_results": invalid_path_results,
        "errors": local_errors,
        "warnings": local_warnings,
    }

    errors.extend(f"{name}: {msg}" for msg in local_errors)
    warnings.extend(f"{name}: {msg}" for msg in local_warnings)

ok = len(errors) == 0
report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "spec_file": spec_path,
    "spec_version": spec.get("version"),
    "machine_count": len(machines),
    "machines": machine_reports,
    "errors": errors,
    "warnings": warnings,
}

with open(report_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

if not ok:
    sys.exit(1)
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "model_check_report=$REPORT_FILE"
echo "model_check_latest=$LATEST_FILE"
echo "model_check_ok=true"
