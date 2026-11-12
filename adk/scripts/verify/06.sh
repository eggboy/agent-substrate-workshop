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

# make adk-verify LAB=6: the end state of "Observe and operate".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 6 (observe and operate)"

check "gateway port-forward is up" gateway_up
check "gateway exports ADK metrics" bash -c "curl -sf '$GATEWAY_LOCAL/metrics' | grep -q '^workshop_adk_requests_total'"
check "template adk-v2 has a golden snapshot" _template_ready "$ATESPACE" adk-v2
check "actor ws runs template adk-v2" bash -c "[[ \"\$(actor_json '$ATESPACE' ws | jq -r '.actorTemplate.name // .spec.actorTemplate.name // empty')\" == adk-v2 ]]"
# Sessions now live on /workspace: a word remembered in a session survives a suspend on the new template.
if adk_turn_ok ws "Remember the word puffin. Reply with: noted"; then
  suspend_actor "$ATESPACE" ws
  out="$("$ADK_DIR/scripts/turn.sh" ws "What word did I ask you to remember? Reply with that word only." verify verify 2>/dev/null || true)"
  check "a session on adk-v2 (SQLite on /workspace) survived the suspend (puffin)" grep -qi puffin <<<"$out"
else
  check "ws completes a turn on adk-v2" false
fi
finish 6
