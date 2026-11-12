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

# One ADK turn through the gateway, timed.
#
#   adk/scripts/turn.sh <actor> "<message>" [session] [user]
#
# Creates the session if needed (idempotent), streams /run_sse, prints the model's text and two
# numbers from curl: time to the first byte of the stream (which includes any resume the router
# did for a suspended actor) and the total turn time. GATEWAY_URL defaults to the local
# port-forward from `make forward-gateway`.
set -euo pipefail

actor="${1:?usage: turn.sh <actor> <message> [session] [user]}"
message="${2:?usage: turn.sh <actor> <message> [session] [user]}"
session="${3:-s1}"
user="${4:-u1}"
app="${ADK_APP:-workspace}"
# ADK_BASE_URL points straight at an ADK server (the Agent Sandbox leg of Lab 5, through a
# port-forward); otherwise the turn goes through the gateway to the named actor.
base="${ADK_BASE_URL:-${GATEWAY_URL:-http://localhost:8081}/adk/$actor}"

# The session call is the first request of the turn: if the actor is suspended, this is the
# request the router parks while the actor resumes, so its time is the resume latency.
# 200 on create, 409 when the session already exists; anything else is a routing or actor problem.
state_before="$( (kubectl ate get actor "$actor" -a "${ATESPACE:-workshop}" -o json 2>/dev/null || true) | jq -r '.status.state // "n/a"' 2>/dev/null | sed 's/ACTOR_STATE_//')"
session_body="$(mktemp)"
read -r code session_time <<<"$(curl -sS -o "$session_body" -w '%{http_code} %{time_total}' -X POST -H 'Content-Type: application/json' -d '{}' \
  "$base/apps/$app/users/$user/sessions/$session")"
case "$code" in
  200|409) ;;
  *) echo "session create: HTTP $code: $(cat "$session_body")" >&2; rm -f "$session_body"; exit 1 ;;
esac
rm -f "$session_body"

body="$(jq -cn --arg app "$app" --arg user "$user" --arg session "$session" --arg text "$message" \
  '{appName:$app, userId:$user, sessionId:$session, streaming:false, newMessage:{role:"user", parts:[{text:$text}]}}')"

out="$(mktemp)"
timing="$(curl -sS -N -o "$out" -w '%{http_code} %{time_starttransfer} %{time_total}' \
  -X POST -H 'Content-Type: application/json' -d "$body" "$base/run_sse")"
read -r code ttfb total <<<"$timing"
if [[ "$code" != 200 ]]; then
  echo "run_sse: HTTP $code: $(head -c 600 "$out")" >&2
  rm -f "$out"
  exit 1
fi
# Final text parts of the stream (each `data:` line is one ADK event), then any error event.
sed -n 's/^data: //p' "$out" | jq -r 'select(.content.role=="model") | .content.parts[]? | select(.text) | .text' | tr -d '\r'
sed -n 's/^data: //p' "$out" | jq -r 'select(.errorMessage) | "[error] " + (.errorCode // "") + " " + (.errorMessage | .[0:300])' >&2
events="$(grep -c '^data: ' "$out" || true)"
rm -f "$out"
printf '[turn] actor=%s was=%s session=%s events=%s session_call=%ss first_byte=%ss total=%ss\n' \
  "$actor" "${state_before:-?}" "$session" "$events" "$session_time" "$ttfb" "$total" >&2
