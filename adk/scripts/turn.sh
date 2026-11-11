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
base="${GATEWAY_URL:-http://localhost:8081}/adk/$actor"

# 200 on create, 400 when the session already exists; anything else is a routing or actor problem.
code="$(curl -sS -o /tmp/turn-session.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' \
  "$base/apps/$app/users/$user/sessions/$session")"
case "$code" in
  200|400) ;;
  *) echo "session create: HTTP $code: $(cat /tmp/turn-session.json)" >&2; exit 1 ;;
esac

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
# Final text parts of the stream (each `data:` line is one ADK event).
sed -n 's/^data: //p' "$out" | jq -r 'select(.content.role=="model") | .content.parts[]? | select(.text) | .text' | tr -d '\r'
events="$(grep -c '^data: ' "$out" || true)"
rm -f "$out"
printf '[turn] actor=%s session=%s events=%s first_byte=%ss total=%ss\n' "$actor" "$session" "$events" "$ttfb" "$total" >&2
