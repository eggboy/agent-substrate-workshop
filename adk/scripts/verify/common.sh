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

# finish <lab>: the official finish, with the ADK catch-up hint.
finish() {
  (( VFAILS == 0 )) || die "ADK lab $1: $VFAILS check(s) failed — see adk/labs/0$1-*/README.md, or run: make adk-catch-up LAB=$(( $1 + 1 )) (add RESET=1 to recreate a broken template and its actors)"
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
  curl -sf "$GATEWAY_LOCAL/adk/$1/apps/${ADK_APP:-workspace}/users/${2:-u1}/sessions" 2>/dev/null | jq -r '.[].id'
}

# adk_session_json <actor> <session> [user]
adk_session_json() {
  curl -sf "$GATEWAY_LOCAL/adk/$1/apps/${ADK_APP:-workspace}/users/${3:-u1}/sessions/$2" 2>/dev/null
}

# adk_turn_ok <actor> <message>: one turn through the gateway answers with at least one model event.
adk_turn_ok() {
  local out
  out="$("$ADK_DIR/scripts/turn.sh" "$1" "$2" "verify" "verify" 2>&1)" || return 1
  grep -q '^\[turn\]' <<<"$out"
}

# actor_not_in_state <atespace> <actor> <STATE>
actor_not_in_state() { [[ "$(actor_state "$1" "$2")" != "$3" ]]; }
