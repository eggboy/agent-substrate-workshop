#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Density run: many ADK sessions, few workers. Random actors get turns from CONCURRENCY
# parallel clients for DURATION seconds while the gateway's idle-suspender frees workers.
#
#   ACTORS="ws-01 ... ws-20" DURATION=120 CONCURRENCY=2 adk/scripts/load.sh
#
# Output: one CSV line per turn (actor, state before, session-call seconds = resume when the
# actor was suspended, total seconds, ok, error), a p50/p95 summary split by whether the turn had
# to resume the actor, and the worker count that served it all.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
duration="${DURATION:-120}"
concurrency="${CONCURRENCY:-2}"
atespace="${ATESPACE:-workshop}"
namespace="${NAMESPACE:-workshop}"
if [[ -z "${ACTORS:-}" ]]; then
  ACTORS="$(for i in $(seq -w 1 20); do printf 'ws-%s ' "$i"; done)"
fi
read -r -a actors <<<"$ACTORS"
out="${OUT:-/tmp/adk-load-$(date +%s).csv}"
# One model call each (the last one adds a single shell-tool round trip). Open-ended tasks such
# as "append a line to a file" turn into 10 to 20 model calls per turn and measure the agent's
# diligence, not the platform.
prompts=(
  "Reply with one word: ok"
  "Reply with one word: fine"
  "Reply with one word: ready"
  "Run the shell command: date +%s   and reply with its output only, nothing else"
)

echo "actor,was,session_call_s,total_s,ok,error" >"$out"
echo "load: ${#actors[@]} actors, $concurrency clients, ${duration}s -> $out"

client() {
  local id="$1" end=$(( $(date +%s) + duration ))
  while (( $(date +%s) < end )); do
    local actor="${actors[RANDOM % ${#actors[@]}]}"
    local prompt="${prompts[RANDOM % ${#prompts[@]}]}"
    local err line
    err="$("$here/turn.sh" "$actor" "$prompt" "load" "client-$id" 2>&1 >/dev/null || true)"
    line="$(grep '^\[turn\]' <<<"$err" || true)"
    local was sc total ok=1 reason=""
    was="$(sed -n 's/.*was=\([^ ]*\).*/\1/p' <<<"$line")"
    sc="$(sed -n 's/.*session_call=\([0-9.]*\)s.*/\1/p' <<<"$line")"
    total="$(sed -n 's/.*total=\([0-9.]*\)s.*/\1/p' <<<"$line")"
    if [[ -z "$total" ]]; then
      ok=0
      reason="$(grep -v '^\[turn\]' <<<"$err" | head -1 | tr ',' ';' | cut -c1-120)"
    fi
    echo "$actor,${was:-?},${sc:-0},${total:-0},$ok,$reason" >>"$out"
  done
}

sampler() {
  local end=$(( $(date +%s) + duration ))
  while (( $(date +%s) < end )); do
    local running suspended
    running="$(kubectl ate get actors -a "$atespace" 2>/dev/null | grep -c ACTOR_STATE_RUNNING || true)"
    suspended="$(kubectl ate get actors -a "$atespace" 2>/dev/null | grep -c ACTOR_STATE_SUSPENDED || true)"
    echo "$(date -u +%T) running=$running suspended=$suspended"
    sleep 10
  done
}

sampler &
for i in $(seq 1 "$concurrency"); do client "$i" & done
wait

echo "== summary"
python3 - "$out" <<'EOF'
import csv, statistics, sys

rows = list(csv.DictReader(open(sys.argv[1])))
ok = [r for r in rows if r["ok"] == "1"]
print(f"turns={len(rows)} ok={len(ok)} failed={len(rows) - len(ok)} actors={len({r['actor'] for r in rows})}")
for r in rows:
    if r["ok"] != "1":
        print(f"  failed: {r['actor']}: {r.get('error', '')}")

def pct(values, p):
    if not values:
        return float("nan")
    values = sorted(values)
    k = max(0, min(len(values) - 1, round(p / 100 * (len(values) - 1))))
    return values[k]

for label, group in (("resumed (was SUSPENDED)", [r for r in ok if r["was"] == "SUSPENDED"]),
                     ("warm (was RUNNING)", [r for r in ok if r["was"] == "RUNNING"])):
    sc = [float(r["session_call_s"]) for r in group]
    total = [float(r["total_s"]) for r in group]
    if group:
        print(f"{label}: n={len(group)} first_request p50={pct(sc,50):.2f}s p95={pct(sc,95):.2f}s | "
              f"turn p50={pct(total,50):.2f}s p95={pct(total,95):.2f}s max={max(total):.2f}s")
    else:
        print(f"{label}: n=0")
EOF
echo "== workers"
kubectl ate get workers -n "$namespace" 2>/dev/null
