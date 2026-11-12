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

# make adk-verify LAB=1: the end state of "An ADK agent as an actor".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 1 (ADK agent as an actor)"

check "ADK image recorded (.workshop/adk-image)" test -s "$STATE_DIR/adk-image"
check "worker pool adk-agents exists" kubectl -n "$NAMESPACE" get workerpool adk-agents
check "template adk-v1 has a golden snapshot" _template_ready "$ATESPACE" adk-v1
check "actor ws exists" actor_json "$ATESPACE" ws
check "actor ws has an egress policy" kubectl ate get egress-policy ws -a "$ATESPACE"
check "gateway port-forward is up" gateway_up
check "ws answers /health through the gateway" curl -sf "$GATEWAY_LOCAL/adk/ws/health"

# A real round trip: a session that remembers across a suspend.
if adk_turn_ok ws "Remember the word kestrel. Reply with: noted"; then
  w_before="$(actor_worker "$ATESPACE" ws)"
  suspend_actor "$ATESPACE" ws
  out="$("$ADK_DIR/scripts/turn.sh" ws "What word did I ask you to remember? Reply with that word only." verify verify 2>/dev/null || true)"
  check "session memory survived the suspend (kestrel)" grep -qi kestrel <<<"$out"
  w_after="$(actor_worker "$ATESPACE" ws)"
  if [[ -n "$w_after" && "$w_after" != "$w_before" ]]; then
    ok "ws resumed on a different worker ($w_before → $w_after)"
  else
    ok "ws resumed on the same worker ($w_after); the scheduler may reuse it"
  fi
else
  check "ws completes a turn through the gateway" false
fi
finish 1
