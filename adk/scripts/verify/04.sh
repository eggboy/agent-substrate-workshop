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

# make adk-verify LAB=4: the end state of "Density, parking and idle".
set -uo pipefail
source "$(dirname "$0")/common.sh"
step "verify ADK lab 4 (density)"

check "gateway port-forward is up" gateway_up
n="$(actor_names "$ATESPACE" | grep -c '^ws-[0-9][0-9]$' || true)"
check "20 density actors ws-01..ws-20 exist ($n found)" test "$n" -ge 20
check "every ws-NN actor has an egress policy" bash -c "for a in \$(kubectl ate get actors -a '$ATESPACE' -o json | jq -r 'if type==\"array\" then . else (.actors // .items // []) end | .[].metadata.name' | grep '^ws-[0-9][0-9]\$'); do kubectl ate get egress-policy \$a -a '$ATESPACE' >/dev/null 2>&1 || exit 1; done"
idle="$(kubectl -n "$NAMESPACE" get deploy gateway -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IDLE_AFTER")].value}' 2>/dev/null)"
check "gateway idle-suspend is on (IDLE_AFTER=$idle)" bash -c "[[ -n '$idle' && '$idle' != 0s ]]"
idle_ok="$(gateway_metric 'workshop_idle_suspends_total{outcome="ok"}')"
check "the gateway idle-suspended actors during the load (workshop_idle_suspends_total{ok}=$idle_ok, want >= 10)" test "${idle_ok%.*}" -ge 10
running="$(count_actors_in_state "$ATESPACE" RUNNING ws-)"
workers="$(kubectl ate get workers -n "$NAMESPACE" 2>/dev/null | awk 'NR>1 && $2=="adk-agents"' | wc -l | tr -d ' ')"
check "more density actors than ADK workers ($n actors, $workers workers)" test "$n" -gt "$workers"
ok "ws-NN actors RUNNING right now: $running (the rest cost no worker)"
finish 4
