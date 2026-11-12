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

# make adk-verify LAB=3: the end state of "Long-running sessions under interruption".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 3 (interruptions)"

check "gateway port-forward is up" gateway_up
check "gateway serves the ADK routes (/adk/{actor}/..., /actors/{actor}/suspend)" gateway_has_route POST /actors/verify-probe/suspend

# Part A: a session on ws carries last_published in its state (set by publish_report after the approval).
published_session() {
  local s
  for s in $(adk_sessions ws); do
    if adk_session_json ws "$s" | jq -e '.state.last_published // empty' >/dev/null 2>&1; then return 0; fi
  done
  return 1
}
check "actor ws exists" actor_json "$ATESPACE" ws
check "Part A: a ws session has a publication approved after the confirmation (state.last_published)" published_session

# Part B: fragile exists and is not CRASHED (reverted), and its template is the exit-on-SIGTERM one.
check "Part B: template adk-exit-v1 has a golden snapshot" _template_ready "$ATESPACE" adk-exit-v1
check "Part B: actor fragile exists" actor_json "$ATESPACE" fragile
check "Part B: fragile was reverted (not CRASHED)" actor_not_in_state "$ATESPACE" fragile CRASHED

# Part C: the gateway performed at least one self-suspend (the shim's SIGTERM path).
self_ok="$(gateway_metric 'workshop_self_suspends_total{outcome="ok"}')"
check "Part C: the gateway completed a synchronous self-suspend (workshop_self_suspends_total{ok}=$self_ok)" test "${self_ok%.*}" -ge 1
check "Part C: ws is not CRASHED" actor_not_in_state "$ATESPACE" ws CRASHED

# Part D: a midturn-* session on ws has both the aborted tool response and a later successful one.
midturn_resumed() {
  local s j
  for s in $(adk_sessions ws | grep '^midturn-' || true); do
    j="$(adk_session_json ws "$s")" || continue
    if jq -e '[.events[].content.parts[]?.functionResponse.response | select(. != null)] | (map(select(.error? == "Invocation was aborted by client.")) | length) >= 1 and (map(select(.status? == "ok")) | length) >= 1' <<<"$j" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}
check "Part D: a midturn session shows the aborted tool and the resumed, completed tool" midturn_resumed
check "ws still answers a turn" adk_turn_ok ws "Reply with one word: verified"
finish 3
