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

# Shared by adk/scripts/verify/NN.sh: the official scripts/verify/common.sh plus ADK helpers.
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/verify/common.sh"

ADK_DIR="$REPO_ROOT/adk"
GATEWAY_LOCAL="http://localhost:${GATEWAY_LOCAL_PORT:-8081}"

# finish <lab>: the official finish, with the ADK catch-up hint (catch-up knows labs 1 to 5).
finish() {
  local hint="see adk/labs/0$1-*/README.md"
  (( $1 < 5 )) && hint="$hint, or run: make adk-catch-up LAB=$(( $1 + 1 )) (add RESET=1 to recreate a broken template and its actors)"
  (( VFAILS == 0 )) || die "ADK lab $1: $VFAILS check(s) failed — $hint"
  ok "ADK lab $1 complete"
}

# gateway_up: the gateway port-forward answers /readyz (starts it if needed).
gateway_up() {
  curl -sf "$GATEWAY_LOCAL/readyz" >/dev/null 2>&1 && return 0
  port_forward gateway "$NAMESPACE" svc/gateway "${GATEWAY_LOCAL_PORT:-8081}" 80 >/dev/null 2>&1 || true
  curl -sf "$GATEWAY_LOCAL/readyz" >/dev/null 2>&1
}

# gateway_metric <name{labels}>: current value of a counter on the gateway's /metrics, 0 if absent.
gateway_metric() {
  curl -sf "$GATEWAY_LOCAL/metrics" 2>/dev/null | awk -v m="$1" 'index($0, m) == 1 {print $2; found=1} END {if (!found) print 0}'
}

# gateway_has_route <method> <path>: the gateway answers something other than 404/405 for the ADK routes.
gateway_has_route() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X "$1" "$GATEWAY_LOCAL$2")"
  [[ "$code" != 404 && "$code" != 405 ]]
}

# adk_sessions <actor> [user]: the actor's session ids for the user (resumes the actor if needed).
adk_sessions() {
  free_worker_for "$1"
  curl -sf "$GATEWAY_LOCAL/adk/$1/apps/${ADK_APP:-workspace}/users/${2:-u1}/sessions" 2>/dev/null | jq -r '.[].id'
}

# adk_session_json <actor> <session> [user]
adk_session_json() {
  curl -sf "$GATEWAY_LOCAL/adk/$1/apps/${ADK_APP:-workspace}/users/${3:-u1}/sessions/$2" 2>/dev/null
}

# adk_turn_ok <actor> <message>: one turn through the gateway answers with at least one model event.
adk_turn_ok() {
  local out
  free_worker_for "$1"
  out="$("$ADK_DIR/scripts/turn.sh" "$1" "$2" "verify" "verify" 2>&1)" || return 1
  grep -q '^\[turn\]' <<<"$out"
}

# actor_not_in_state <atespace> <actor> <STATE>
actor_not_in_state() { [[ "$(actor_state "$1" "$2")" != "$3" ]]; }

# free_worker_for <actor>: with two ADK workers and idle-suspend possibly off (Lab 3), a third
# RUNNING actor would wait out the router's parking budget and fail. Suspend the other ADK actors
# that are RUNNING so the one under test can be placed.
free_worker_for() {
  local keep="$1" a
  for a in $(_actors_list "$ATESPACE" | jq -r '.[] | select((.status.state // "") == "ACTOR_STATE_RUNNING" and ((.actorTemplate.name // "") | startswith("adk-"))) | .metadata.name'); do
    [[ "$a" == "$keep" ]] && continue
    kubectl ate suspend actor "$a" -a "$ATESPACE" >/dev/null 2>&1 || true
  done
  return 0
}
