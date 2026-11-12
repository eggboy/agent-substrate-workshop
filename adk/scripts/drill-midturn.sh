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

# Eviction in the middle of a turn: the agent is inside a slow tool call when its worker pod is
# deleted. What the client sees, what the actor does after it resumes elsewhere, and whether
# the tool ran once or twice.
#
#   adk/scripts/drill-midturn.sh <actor> [session] [user]
set -euo pipefail

actor="${1:?usage: drill-midturn.sh <actor> [session] [user]}"
session="${2:-midturn-$(date +%s)}"
user="${3:-u1}"
app="${ADK_APP:-workspace}"
atespace="${ATESPACE:-workshop}"
base="${GATEWAY_URL:-http://localhost:8081}/adk/$actor"
here="$(cd "$(dirname "$0")" && pwd)"
stream="$(mktemp)"

curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{}' "$base/apps/$app/users/$user/sessions/$session"

echo "== 1. start a turn with a 20 s tool call, in the background (the ADK shell tool times out at 30 s)"
body="$(jq -cn --arg app "$app" --arg user "$user" --arg session "$session" \
  '{appName:$app, userId:$user, sessionId:$session, streaming:false, newMessage:{role:"user", parts:[{text:"Run exactly this shell command once and tell me its output verbatim: sleep 20 && echo SLEPT-OK-$RANDOM"}]}}')"
t0=$(date +%s%3N)
( curl -sS -N -o "$stream" -w '%{http_code} %{time_total}\n' -X POST -H 'Content-Type: application/json' -d "$body" "$base/run_sse" > "$stream.status" 2>&1 || true ) &
client=$!
sleep 8
echo "$(date -u +%T.%3N) tool call should be running; events so far: $(grep -c '^data: ' "$stream" || true)"

echo "== 2. delete the worker pod under the actor"
"$here/drill-evict.sh" "$actor" "$atespace"

echo "== 3. what the client saw"
wait "$client" || true
echo "client: HTTP/time $(cat "$stream.status" | tail -1) after $(( $(date +%s%3N) - t0 )) ms, events=$(grep -c '^data: ' "$stream" || true)"
sed -n 's/^data: //p' "$stream" | jq -c '{author, calls: [.content.parts[]?.functionCall.name // empty], responses: [.content.parts[]?.functionResponse.name // empty], text: ([.content.parts[]?.text // empty] | join(" ") | .[0:80])}' 2>/dev/null | tail -4

echo "== 4. session history: the tool was abandoned when the stream died"
history() {
  curl -sS "$base/apps/$app/users/$user/sessions/$session" | jq -c '[.events[] | {author, calls: [.content.parts[]?.functionCall.name // empty], responses: [.content.parts[]?.functionResponse.response // empty], text: ([.content.parts[]?.text // empty] | join(" ") | .[0:80])} | select((.calls|length)>0 or (.responses|length)>0 or (.text|length)>0)]'
}
sleep 2
history
inv="$(curl -sS "$base/apps/$app/users/$user/sessions/$session" | jq -r '[.events[] | select(.author=="user")][0].invocationId')"

echo "== 5. ADK resume: the same invocation id, no new message (replays the log, re-runs the tool)"
t0=$(date +%s%3N)
resume="$(jq -cn --arg app "$app" --arg user "$user" --arg session "$session" --arg inv "$inv" \
  '{appName:$app, userId:$user, sessionId:$session, invocationId:$inv, streaming:false}')"
curl -sS -N -X POST -H 'Content-Type: application/json' -d "$resume" "$base/run_sse" | sed -n 's/^data: //p' \
  | jq -c '{author, calls: [.content.parts[]?.functionCall.name // empty], responses: [.content.parts[]?.functionResponse.response // empty], text: ([.content.parts[]?.text // empty] | join(" ") | .[0:120])}'
echo "resume turn: $(( $(date +%s%3N) - t0 )) ms (the 20 s sleep ran again: ADK replays, Substrate does not)"
rm -f "$stream" "$stream.status"
