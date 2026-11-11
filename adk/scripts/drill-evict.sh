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

# Eviction drill: delete the worker Pod under a RUNNING actor and watch what the actor does
# with the SIGTERM Substrate forwards to it.
#
#   adk/scripts/drill-evict.sh <actor> [atespace]
#
# With the ADK image's shim as PID 1 the actor ends SUSPENDED (the shim asked the gateway for
# a synchronous suspend); with SHIM_EXIT_ON_SIGTERM=1 (or any server that exits on SIGTERM) it
# ends CRASHED and `kubectl ate revert actor` is the way back. The script prints a timestamped
# state trace, the time from delete to the final state, the gateway's self-suspend counter and
# the worker Pod's grace period, so the two runs can be compared side by side.
set -euo pipefail

actor="${1:?usage: drill-evict.sh <actor> [atespace]}"
atespace="${2:-${ATESPACE:-workshop}}"
namespace="${NAMESPACE:-workshop}"
gateway="${GATEWAY_URL:-http://localhost:8081}"

state() { kubectl ate get actor "$actor" -a "$atespace" -o json 2>/dev/null | jq -r '.status.state'; }
worker_pod() { kubectl ate get actor "$actor" -a "$atespace" -o json 2>/dev/null | jq -r '.status.workerAssignment.workerPod // empty'; }
now_ms() { date +%s%3N; }
self_suspends() { curl -sf "$gateway/metrics" 2>/dev/null | awk '/^workshop_self_suspends_total\{outcome="ok"\}/ {print $2}'; }

if [[ "$(state)" != ACTOR_STATE_RUNNING ]]; then
  echo "$actor is $(state); it must be RUNNING (send it a turn first)" >&2
  exit 1
fi
pod="$(worker_pod)"
[[ -n "$pod" ]] || { echo "cannot find the worker pod of $actor" >&2; exit 1; }
grace="$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.spec.terminationGracePeriodSeconds}')"
before="$(self_suspends || echo 0)"
echo "actor=$actor worker_pod=$pod terminationGracePeriodSeconds=$grace self_suspends_before=${before:-0}"

t0="$(now_ms)"
kubectl -n "$namespace" delete pod "$pod" --wait=false >/dev/null
echo "$(date -u +%T.%3N) deleted $pod (SIGTERM is on its way to the actor)"
last=""
for _ in $(seq 1 600); do
  s="$(state)"
  if [[ "$s" != "$last" ]]; then
    echo "$(date -u +%T.%3N) +$(( $(now_ms) - t0 ))ms state=$s"
    last="$s"
  fi
  case "$s" in ACTOR_STATE_SUSPENDED|ACTOR_STATE_CRASHED) break ;; esac
  sleep 0.5
done
after="$(self_suspends || echo 0)"
echo "final_state=$last elapsed_ms=$(( $(now_ms) - t0 )) self_suspends_after=${after:-0}"
kubectl -n "$namespace" get pod "$pod" -o custom-columns='POD:.metadata.name,PHASE:.status.phase,DELETION:.metadata.deletionTimestamp' 2>/dev/null || echo "pod $pod is gone"
